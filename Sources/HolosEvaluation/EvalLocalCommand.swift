import Foundation
import HolosCore
import HolosMeeting
import HolosStorage

/// `voiceislocal eval local` as a library call: works out the meeting's languages and today's vocabulary, then, under
/// the session's processing lease, runs `EvalLocal.run` through the caller's interruption.
///
/// Rules:
/// 1. The vocabulary is read before the lease is taken, and only for a new run that asks for one (a resumed run
///    uses the vocabulary saved in its run.json; today's files are not read). One that cannot be read throws
///    `VocabularyUnreadable`, before anything is transcribed.
/// 2. A stopped run (`CancellationError`) is said, then rethrown; what is saved is kept for a resume.
public enum EvalLocalCommand {
    public struct Request: Sendable {
        public var session: URL
        /// How the user named the session, for the next command it suggests.
        public var sessionArgument: String
        public var language: String?
        /// Transcribe without any vocabulary.
        public var noVocabulary: Bool
        public var wordFixes: Bool
        public var runID: String?
        public var backend: EvalLocal.Backend
        public var files: EvalUserFiles

        public init(session: URL, sessionArgument: String, language: String? = nil, noVocabulary: Bool = false,
                    wordFixes: Bool = true, runID: String? = nil, backend: EvalLocal.Backend = .apple,
                    files: EvalUserFiles = EvalUserFiles()) {
            self.session = session; self.sessionArgument = sessionArgument; self.language = language
            self.noVocabulary = noVocabulary; self.wordFixes = wordFixes; self.runID = runID; self.backend = backend
            self.files = files
        }
    }

    /// Today's vocabulary could not be read (rule 1); `message` says what to do.
    public struct VocabularyUnreadable: Error, Sendable, Equatable {
        public var message: String
    }

    /// The run's transcription dependencies (the CLI's word-fix inputs and Whisper model).
    public struct Dependencies: Sendable {
        public var languages: LanguageDetectionDependencies
        public var wordFixes: WordFixDependencies
        public var deepTranscription: DeepTranscriptionDependencies

        public init(languages: LanguageDetectionDependencies = .live, wordFixes: WordFixDependencies = .none,
                    deepTranscription: DeepTranscriptionDependencies = .none) {
            self.languages = languages; self.wordFixes = wordFixes; self.deepTranscription = deepTranscription
        }
    }

    /// Runs the local candidate (rules 1–2) and returns its record. Throws `VocabularyUnreadable`, what
    /// `EvalLocal` refuses, a busy processing lease, and `CancellationError` (said first).
    @discardableResult
    public static func run(_ request: Request, dependencies: Dependencies, interruption: any EvalInterruption,
                           report: @escaping @Sendable (EvalCommandMessage) -> Void) async throws -> LocalRunRecord {
        let directory = request.session
        let languages = try EvalLocal.languages(session: directory, language: request.language)
        var vocabulary: [String]?
        // A resumed run uses the vocabulary saved in its run.json; today's files are not read.
        if !request.noVocabulary, request.runID == nil {
            do {
                let names = request.files.names
                vocabulary = request.backend == .whisper
                    ? try EvalLocal.whisperVocabulary(session: directory,
                                                      wordList: try request.files.wordList.load().terms, names: names)
                    : RecognizerVocabulary.meeting(
                        wordList: try request.files.wordList.load().terms, names: names,
                        corrections: try CorrectionList.load(from: request.files.corrections),
                        languages: languages)
            } catch {
                throw VocabularyUnreadable(message: "Could not read the vocabulary (pass --no-vocabulary to go "
                    + "without): " + error.localizedDescription)
            }
        }
        let lease = try SessionArchive.acquireProcessingLease(at: directory)
        defer { lease.release() }
        let options = EvalLocal.Options(language: request.language, runID: request.runID,
                                        savedVocabulary: request.runID != nil && !request.noVocabulary,
                                        wordFixes: request.wordFixes, backend: request.backend)
        let strings = vocabulary
        do {
            let record = try await interruption.run { () async throws in
                try await EvalLocal.run(session: directory, options: options, vocabulary: strings,
                                        dependencies: dependencies.languages, wordFixes: dependencies.wordFixes,
                                        deepTranscription: dependencies.deepTranscription,
                                        progress: { report(.note($0)) })
            }
            report(.note("Local run \(record.id) is complete. Next: voiceislocal eval compare "
                + "\(request.sessionArgument) --local \(record.id)"))
            report(.output(EvalPaths.localRun(record.id, in: directory).path))
            return record
        } catch {
            if error is CancellationError {
                report(.note("Cancelled. What is saved is kept; run the same command again to resume."))
            }
            throw error
        }
    }
}
