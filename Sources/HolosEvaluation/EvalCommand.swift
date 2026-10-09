import Foundation
import HolosCore
import HolosMeeting
import HolosStorage

/// One thing an eval command says while it works: `.output` is content (stdout), `.note` a message (stderr). The
/// commands report them as they happen, so they keep their order with the work, a prompt, and a failure.
public enum EvalCommandMessage: Sendable, Equatable {
    case output(String)
    case note(String)
}

/// Runs a step of an eval command so that its caller can stop it: the CLI cancels the step on Ctrl-C or SIGTERM
/// (and records the exit code), and a step that returned after such a signal still ends with `CancellationError`.
public protocol EvalInterruption: Sendable {
    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T
}

/// Runs each step as it is: nothing stops it but cancelling the task (tests, and callers without signals).
public struct EvalUninterrupted: EvalInterruption {
    public init() {}

    public func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await operation()
    }
}

/// The user's files the eval commands read, and `eval apply` adds to: the word list, corrections.json, and the people
/// store (for names). The defaults are the support folder's (`HOLOS_SUPPORT_DIR` when set).
public struct EvalUserFiles: Sendable {
    public var wordList: WordListStore
    public var corrections: URL
    public var people: SpeakerProfileStore

    public init(wordList: WordListStore = WordListStore(), corrections: URL = CorrectionList.defaultURL,
                people: SpeakerProfileStore = SpeakerProfileStore()) {
        self.wordList = wordList; self.corrections = corrections; self.people = people
    }

    /// People's names, sorted.
    var names: [String] { VoiceProfileService.profileNames(store: people).values.sorted() }

    /// The sources of the meeting vocabulary the app gives the recorder (`RecognizerVocabulary.meeting`), for
    /// `eval cloud --vocabulary`: the word list, people's names, and correction words for the meeting's languages. A
    /// damaged words.json or corrections.json stops the run rather than sending less than --vocabulary asked for.
    public var cloudVocabulary: CloudEvaluation.VocabularySource {
        let files = self
        return CloudEvaluation.VocabularySource(
            wordList: {
                do { return try files.wordList.load().terms } catch {
                    throw HolosError.invalidInput("Could not read the word list for --vocabulary: "
                        + error.localizedDescription)
                }
            },
            names: { files.names },
            terms: { languages in
                do { return try CorrectionList.load(from: files.corrections).vocabulary(languages: languages) }
                catch {
                    throw HolosError.invalidInput("Could not read corrections.json for --vocabulary: "
                        + error.localizedDescription)
                }
            })
    }

    /// The word list's terms and the corrections' meant phrases, for a comparison's Terms section. One that cannot be
    /// read is said (`report`) and left out; the comparison goes on.
    func vocabularyTerms(report: (EvalCommandMessage) -> Void) -> [EvalTerms.Term] {
        var wordList: [String] = []
        var meant: [String] = []
        do { wordList = try self.wordList.load().terms } catch {
            report(.note("Note: the word list could not be read (\(error.localizedDescription)); its terms are not counted."))
        }
        do { meant = try CorrectionList.load(from: corrections).entries.map(\.meant) } catch {
            report(.note("Note: corrections.json could not be read (\(error.localizedDescription)); its phrases are not counted."))
        }
        return EvalTerms.terms(wordList: wordList, corrections: meant)
    }
}

/// `voiceislocal eval delete`: under the session's processing lease, deletes one run's files or every evaluation
/// file of the session.
public enum EvalDeleteCommand {
    public struct Request: Sendable {
        public var session: URL
        /// Nil: every evaluation file.
        public var runID: String?

        public init(session: URL, runID: String?) {
            self.session = session; self.runID = runID
        }
    }

    public struct Outcome: Sendable, Equatable {
        /// Something was deleted.
        public var removed: Bool
        /// "Deleted." or "Nothing to delete."
        public var message: String { removed ? "Deleted." : "Nothing to delete." }
    }

    /// Throws when another process holds the processing lease, or a run cannot be deleted.
    public static func run(_ request: Request) throws -> Outcome {
        let directory = request.session
        let lease = try SessionArchive.acquireProcessingLease(at: directory)
        defer { lease.release() }
        let removed = try request.runID.map { try EvalStore.deleteRun($0, in: directory) }
            ?? EvalStore.deleteAll(in: directory)
        return Outcome(removed: removed)
    }
}
