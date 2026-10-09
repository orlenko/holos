import Foundation
import HolosCore
import HolosStorage

/// `voiceislocal eval cloud` (docs/reference-evaluation.md, "Cloud reference") as a library call: under the session's
/// processing lease, prepares the run (`CloudEvaluation.prepare`), asks for consent through the caller, and uploads
/// (`CloudEvaluation.upload`). The library never prompts: `consent` is the caller's question.
///
/// Rules:
/// 1. Nothing is uploaded unless `consent` returns `.proceed`; it is asked only when something is left to send (a run
///    whose every segment is saved is finished without asking). Declining, or having no terminal, discards the
///    prepared renders.
/// 2. The processing lease is held from before the stale work folders are removed until the upload ends.
/// 3. Preparation and upload each run through `interruption`, so the caller can stop either; the consent question
///    runs outside it.
/// 4. What the command says goes to `report` in order with the steps and the question.
public enum EvalCloudCommand {
    public struct Request: Sendable {
        public var session: URL
        /// How the user named the session, for the next command it suggests.
        public var sessionArgument: String
        public var options: CloudEvaluation.Options
        public var vocabulary: CloudEvaluation.VocabularySource
        /// The client the segments are sent with (its transport and key).
        public var client: CloudTranscriptionClient

        public init(session: URL, sessionArgument: String, options: CloudEvaluation.Options,
                    vocabulary: CloudEvaluation.VocabularySource, client: CloudTranscriptionClient) {
            self.session = session; self.sessionArgument = sessionArgument; self.options = options
            self.vocabulary = vocabulary; self.client = client
        }
    }

    /// How a run ended once it was prepared.
    public enum Outcome: Sendable, Equatable {
        /// Every pending segment was uploaded (`count` of them; 0 when the run only needed finishing).
        case uploaded(count: Int)
        /// The user said no; nothing was uploaded.
        case declined
        /// No terminal to ask at and no `--yes`; nothing was uploaded.
        case noTerminal
        /// The upload failed; what is saved is kept for a resume.
        case failed
        /// The upload was stopped (the interruption, or cancelling the task); what is saved is kept.
        case cancelled
    }

    /// Prepares, asks, and uploads (rules 1–4). Throws, with nothing uploaded, when another process holds the lease or
    /// the preparation fails or is stopped (the stale work folder is removed again first). A failed or stopped upload
    /// is said and returned (`.failed`, `.cancelled`), not thrown.
    public static func run(_ request: Request, interruption: any EvalInterruption,
                           consent: () -> ConsentGate.Decision,
                           report: @escaping @Sendable (EvalCommandMessage) -> Void) async throws -> Outcome {
        let directory = request.session
        let options = request.options
        let vocabulary = request.vocabulary
        let lease = try SessionArchive.acquireProcessingLease(at: directory)
        defer { lease.release() }
        CloudEvaluation.removeStaleWork(session: directory)

        let prepared: CloudEvaluation.Prepared
        do {
            prepared = try await interruption.run { () async throws in
                try CloudEvaluation.prepare(session: directory, options: options, vocabulary: vocabulary,
                                            progress: { report(.note($0)) })
            }
        } catch {
            CloudEvaluation.removeStaleWork(session: directory)
            throw error
        }
        if prepared.pendingCount == 0 {
            report(.note("Every segment of run \(prepared.record.id) is already saved; finishing it."))
        } else {
            for line in prepared.summaryLines { report(.note(line)) }
            report(.note("The audio leaves this Mac: go ahead only if everyone recorded agreed to that."))
            switch consent() {
            case .proceed:
                break
            case .declined:
                CloudEvaluation.discard(prepared)
                report(.note("Nothing was uploaded."))
                return .declined
            case .noTerminal:
                CloudEvaluation.discard(prepared)
                report(.note("Nothing was uploaded: there is no terminal to confirm at. Pass --yes to upload "
                    + "without asking."))
                return .noTerminal
            }
        }
        let client = request.client
        do {
            let outcome = try await interruption.run { () async throws in
                try await CloudEvaluation.upload(prepared, client: client, progress: { report(.note($0)) })
            }
            report(.note("Uploaded \(outcome.uploaded) segments. Next: voiceislocal eval compare "
                + request.sessionArgument))
            report(.output(EvalPaths.cloudRun(prepared.record.id, in: directory).path))
            return .uploaded(count: outcome.uploaded)
        } catch {
            let saved = EvalStore.savedSegments(prepared.record, in: directory)
            let total = prepared.record.tracks.reduce(0) { $0 + $1.segments.filter { !$0.silent }.count }
            let message = error is CancellationError ? "Cancelled." : CloudTranscriptionClient.redacted(
                error.localizedDescription)
            report(.note("\(message) \(saved) of \(total) segments are saved; run the same command again to "
                + "resume run \(prepared.record.id)."))
            return error is CancellationError ? .cancelled : .failed
        }
    }
}
