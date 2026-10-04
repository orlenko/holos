import ArgumentParser
import Foundation
import FoundationModels
import HolosCore
import HolosDictation
import HolosMeeting
import HolosStorage

extension Session {
    /// `voiceislocal session summarize` (docs/meeting-design.md §4.17).
    struct Summarize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write a finished session's title, summary, key points and action items with Apple Intelligence.",
            discussion: """
                Apple's on-device model reads the current transcript, with speaker names, part by part, and writes a \
                short title (at most 8 words), a one- or two-sentence summary, key points and action items into the \
                session's summary.json; the transcript files (Markdown and JSON) are rewritten with them. Nothing \
                leaves this Mac. The Meetings list shows the title unless you named the meeting yourself. A summary \
                of the current transcript is kept unless --force; Voice is Local makes one after each meeting, and \
                again when a final transcript replaces the recorded one. Needs Apple Intelligence turned on. Exits \
                0 when the summary was written or is up to date, 3 when it was written but the transcript files \
                could not be rewritten, and 1 otherwise (the reason is printed), also when another summary or a final \
                transcript is being made: one runs at a time on this Mac. Ctrl-C stops it without writing anything.
                """)

        @Argument(help: "Path to a .holos folder, or a session ID.") var path: String
        @Flag(help: "Summarize again even when the summary is of the current transcript.") var force = false
        @Flag(help: "Print the result as JSON (with the summary).") var json = false

        mutating func run() async throws {
            let session = try SessionLocator.resolve(path)
            let sessionID = (try? SessionArchive.readManifest(at: session).id)
                ?? session.deletingPathExtension().lastPathComponent
            // The people store read once for the prompt, and again at the save to check nothing changed meanwhile. One
            // that cannot be read (a newer build wrote it, it is damaged) fails at once, before the model.
            let outcome: SessionSummarizeCommand.Outcome
            switch Result(catching: { try SessionSummarizeCommand.VoiceInputs.read() }) {
            case .failure(let error):
                outcome = SessionSummarizeCommand.Outcome(
                    sessionID: sessionID, status: .failed,
                    message: "Cannot read the people store: \(error.localizedDescription)", exitCode: 1)
            case .success(let voice):
                outcome = try await summarize(session, sessionID: sessionID, voice: voice)
            }
            if json {
                try Console.json(outcome)
                if outcome.exitCode != 0 { Console.error(outcome.message) }
            } else if let summary = outcome.summary, outcome.exitCode != 1 {
                Console.output(summary.title)
                Console.output("")
                Console.output(summary.summary)
                for (heading, items) in [("Key points", summary.points), ("Action items", summary.actions)]
                where !items.isEmpty {
                    Console.output("")
                    Console.output("\(heading):")
                    for item in items { Console.output("- \(item)") }
                }
                if outcome.exitCode != 0 { Console.error(outcome.message) }
            } else if outcome.exitCode == 0 {
                Console.output(outcome.message)
            } else {
                Console.error(outcome.message)
            }
            if outcome.exitCode != 0 { throw ExitCode(outcome.exitCode) }
        }

        /// The summary under the background-job lock, cancelled by Ctrl-C or SIGTERM. One expensive background job at
        /// a time on this Mac, held for the command's whole life: a final transcript waits for it and it waits for
        /// one, also across an app relaunch (docs/meeting-design.md §4.17).
        private func summarize(_ session: URL, sessionID: String, voice: SessionSummarizeCommand.VoiceInputs)
            async throws -> SessionSummarizeCommand.Outcome {
            let request = SessionSummarizeCommand.Request(
                session: session, force: force, selfName: voice.selfName, profileNames: voice.names,
                applyRecognition: voice.recognition, profileStore: SpeakerProfileStore())
            guard let held = try DeepTranscriptionLock.take(
                DeepTranscriptionLock.Holder(pid: getpid(), sessionID: sessionID, force: force,
                                             kind: DeepTranscriptionLock.Holder.summaryKind)) else {
                return SessionSummarizeCommand.Outcome(sessionID: sessionID, status: .busy,
                                                       message: DeepTranscriptionLock.busyMessage, exitCode: 1)
            }
            defer { held.release() }
            // Ctrl-C or SIGTERM (the app, when a meeting starts) cancels it; nothing is written once cancelled
            // before the save, and the save itself is never cut short.
            let work = CancellableStart<SessionSummarizeCommand.Outcome>()
            let interrupt = InterruptCancellation(notice: {
                Console.error("Stopping… (press Ctrl-C again to quit at once)")
            }) { work.cancel() }
            defer { interrupt.restore() }
            return try await work.start {
                await SessionSummarizeCommand.run(request) { OnDeviceSummary.model(language: $0) }
            }.value
        }
    }
}

/// Apple's on-device model for meeting summaries: the dictation fix's model and guardrails (summarizing the speakers'
/// own words is a content transformation), structured output (`@Generable`), greedy sampling, a fresh session per call.
enum OnDeviceSummary {
    @Generable(description: "Notes on one part of a meeting")
    struct PartNotes {
        // No `refused` field here: measured on three real meetings, Apple's model set it on parts it summarized
        // well without it (placed first), or failed to produce parseable output (placed last). A refusal of a part
        // comes as the framework's own refusal error, in any language, and the phrase list catches the rest.
        @Guide(description: "Two to five short notes, one sentence each", .maximumCount(6))
        var notes: [String]
    }

    @Generable(description: "A meeting's title and summary")
    struct Summary {
        @Guide(description: "At most 8 words naming what was discussed; no date, does not begin with Meeting")
        var title: String
        @Guide(description: "One or two sentences on what the meeting was about and what came out of it")
        var summary: String
        @Guide(description: "Up to 5 main points or decisions, one short sentence each", .maximumCount(5))
        var keyPoints: [String]
        @Guide(description: "Up to 5 tasks someone agreed to do, with the person; empty when none", .maximumCount(5))
        var actionItems: [String]
        @Guide(description: "True only if you could not summarize this text at all; false otherwise")
        var refused: Bool
    }

    /// The model for a meeting mostly in `language`, or why it cannot be used.
    static func model(language: String) -> SessionSummarizeCommand.ModelChoice {
        if let reason = OnDeviceFix.unavailableReason { return .unavailable(reason) }
        let model = SystemLanguageModel(guardrails: .permissiveContentTransformations)
        guard model.supportsLocale(Locale(identifier: language)) else {
            return .unavailable("Apple Intelligence does not support \(DictationLanguage.name(of: language))")
        }
        return .available(MeetingSummaryModel(
            name: MeetingSummaryModel.appleOnDevice, contextTokens: model.contextSize,
            notes: { instructions, prompt in
                let session = LanguageModelSession(model: model, instructions: instructions)
                do {
                    let answer = try await session.respond(
                        to: prompt, generating: PartNotes.self,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 600)).content
                    return MeetingSummaryNotes(notes: answer.notes)
                } catch {
                    throw mapped(error)
                }
            },
            summary: { instructions, prompt in
                let session = LanguageModelSession(model: model, instructions: instructions)
                do {
                    let answer = try await session.respond(
                        to: prompt, generating: Summary.self,
                        options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 800)).content
                    return MeetingSummaryDraft(title: answer.title, summary: answer.summary, points: answer.keyPoints,
                                               actions: answer.actionItems, refused: answer.refused)
                } catch {
                    throw mapped(error)
                }
            }))
    }

    /// The model's errors the summarizer acts on: a prompt too long for the context (the part is split), a refusal
    /// or guardrail (the part is left out), and a busy system (tried again later).
    static func mapped(_ error: any Error) -> any Error {
        guard let error = error as? LanguageModelError else { return error }
        switch error {
        case .contextSizeExceeded: return MeetingSummaryModelError.contextExceeded
        case .guardrailViolation, .refusal: return MeetingSummaryModelError.refused
        case .rateLimited: return MeetingSummaryModelError.busy
        default: return error
        }
    }
}
