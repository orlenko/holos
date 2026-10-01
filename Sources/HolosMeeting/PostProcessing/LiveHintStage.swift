import Foundation
import HolosCore
import HolosStorage

/// Reconciles corrections saved while recording with the final transcript and speaker run. Text runs after language
/// merging and before automatic word fixes and alignment; speaker names run after alignment and before exports.
enum LiveHintStage {
    struct TextOutcome {
        var transcript: Transcript
        var hints: [LiveHint]
        var note: String? = nil
        var problem: String? = nil
        var labelsPreserved = false
        var speakerHeadIncomplete = false
    }

    struct SpeakerOutcome {
        var note: String? = nil
        var problem: String? = nil
    }

    private struct IncompletePublication: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func applyText(session: URL, transcript: Transcript, lease: ProcessingLease) async throws -> TextOutcome {
        let hints: [LiveHint]
        do {
            hints = try LiveHintStore.read(session: session).hints
        } catch {
            return TextOutcome(transcript: transcript, hints: [],
                               problem: "Live corrections could not be read: \(error.localizedDescription)")
        }
        let result = LiveHints.applyingText(hints, to: transcript)
        guard result.applied > 0 else {
            let problem = result.unmatched > 0
                ? "\(result.unmatched) live text \(result.unmatched == 1 ? "correction could" : "corrections could") not be matched to the final transcript."
                : nil
            guard result.alreadyApplied > 0 else {
                return TextOutcome(transcript: transcript, hints: hints, problem: problem)
            }
            do {
                let repaired = try await repairPreservedHeadIfNeeded(transcript, session: session, lease: lease)
                return TextOutcome(transcript: transcript, hints: hints, problem: problem,
                                   labelsPreserved: repaired)
            } catch let error where !(error is CancellationError) {
                let message = "Live text corrections were saved, but their speaker labels could not be published: "
                    + error.localizedDescription
                return TextOutcome(transcript: transcript, hints: hints,
                                   problem: [problem, message].compactMap { $0 }.joined(separator: " "),
                                   speakerHeadIncomplete: true)
            }
        }
        do {
            let labelsPreserved = try await publish(result.transcript, base: transcript, result: result,
                                                    session: session, lease: lease)
            let text = result.applied == 1 ? "Applied 1 live text correction."
                : "Applied \(result.applied) live text corrections."
            let problem = result.unmatched > 0
                ? "\(result.unmatched) live text \(result.unmatched == 1 ? "correction could" : "corrections could") not be matched to the final transcript."
                : nil
            return TextOutcome(transcript: result.transcript, hints: hints, note: text, problem: problem,
                               labelsPreserved: labelsPreserved)
        } catch let error where !(error is CancellationError) {
            let incomplete = error is IncompletePublication
            let message = incomplete
                ? "Live text corrections were saved, but their speaker labels could not be published: \(error.localizedDescription)"
                : "Live text corrections could not be saved: \(error.localizedDescription)"
            return TextOutcome(transcript: incomplete ? result.transcript : transcript, hints: hints,
                               problem: message, speakerHeadIncomplete: incomplete)
        }
    }

    static func applySpeakers(_ hints: [LiveHint], session: URL, transcript: Transcript,
                              profiles: SpeakerProfileStore?) -> SpeakerOutcome {
        guard hints.contains(where: { if case .nameSpeaker = $0.action { true } else { false } }) else {
            return SpeakerOutcome()
        }
        do {
            let names = profiles.map { VoiceProfileService.profileNames(store: $0) } ?? [:]
            let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: names,
                                                           applyRecognition: profiles.map {
                                                               VoiceProfileService.recognitionAllowed(store: $0)
                                                           } ?? true)
            guard snapshot.transcript.id == transcript.id, let projection = snapshot.projection else {
                return SpeakerOutcome(problem: "Live speaker names could not be applied because this transcript has no speaker labels.")
            }
            let applied = Set(projection.appliedEditIDs)
            let protected = Set(snapshot.journal.edits.compactMap { edit -> String? in
                guard applied.contains(edit.id), case .rename(let speakerID, _) = edit.action else { return nil }
                return speakerID
            })
            let proposed = LiveHints.speakerActions(hints, projection: projection, transcript: transcript)
            let actions = proposed.filter { action in
                guard case .rename(let speakerID, _) = action else { return true }
                return !protected.contains(speakerID)
            }
            guard !actions.isEmpty else {
                // An effective rename means this hint was applied before or superseded later; either is complete.
                if !proposed.isEmpty { return SpeakerOutcome() }
                return SpeakerOutcome(problem: "Live speaker names could not be matched to the final speaker labels.")
            }
            let changed = try SpeakerEditor.applyUnlessUnchanged(actions, view: projection, session: session,
                                                                 source: "live", regenerateExports: false,
                                                                 profileNames: names, profiles: profiles)
            guard changed != nil else { return SpeakerOutcome() }
            let count = actions.count
            return SpeakerOutcome(note: count == 1 ? "Applied 1 live speaker name."
                                                   : "Applied \(count) live speaker names.")
        } catch {
            return SpeakerOutcome(problem: "Live speaker names could not be saved: \(error.localizedDescription)")
        }
    }

    private static func publish(_ transcript: Transcript, base: Transcript, result: LiveHints.TextOutcome,
                                session: URL, lease: ProcessingLease) async throws -> Bool {
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        do {
            let preserved = try await SessionArchive.withSpeakerLockAsync(at: session) { () async throws -> Bool in
                guard try SessionFiles.currentTranscript(session: session)?.id == base.id else {
                    throw HolosError.unavailable("The transcript changed while live corrections were being saved.")
                }
                var plan: SpeakerTranscriptRetarget.Plan?
                if let head = try SpeakerAnalysis.headState(session: session, transcript: base),
                   head.usableRunID != nil {
                    let snapshot = try SpeakerSessionSnapshot.load(session: session)
                    plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: transcript)
                    if head.hasEdits, plan == nil {
                        throw HolosError.invalidInput("The edited speaker labels cannot be kept across the live correction.")
                    }
                }
                try Task.checkCancellation()
                if let plan { try SpeakerTranscriptRetarget.stage(plan, session: session) }
                try await archive.recordEvent(kind: MeetingEventKind.liveHintsApplied, details: [
                    "transcriptID": transcript.id, "base": base.id,
                    "applied": String(result.applied), "unmatched": String(result.unmatched),
                ])
                try await archive.saveTranscript(transcript, writeLegacyExports: false)
                if let plan {
                    do { try SpeakerTranscriptRetarget.publishHead(plan, session: session) } catch {
                        throw IncompletePublication(message: error.localizedDescription)
                    }
                }
                return plan != nil
            }
            await archive.releaseLock()
            return preserved
        } catch {
            await archive.releaseLock()
            throw error
        }
    }

    /// Repairs the only incomplete text publication: the corrected transcript is current while its staged speaker
    /// run did not become head. The old head remains a complete snapshot, so the same retarget can be made again.
    private static func repairPreservedHeadIfNeeded(_ transcript: Transcript, session: URL,
                                                    lease: ProcessingLease) async throws -> Bool {
        let initial = try SpeakerAnalysis.headState(session: session, transcript: transcript)
        guard let initial, !initial.sameTranscript, initial.run != nil else { return false }
        let archive = try SessionArchive.openForMaintenance(at: session, lease: lease)
        do {
            let repaired = try await SessionArchive.withSpeakerLockAsync(at: session) { () async throws -> Bool in
                guard try SessionFiles.currentTranscript(session: session)?.id == transcript.id else {
                    throw HolosError.invalidInput("The transcript changed while its speaker labels were being repaired.")
                }
                guard let head = try SpeakerAnalysis.headState(session: session, transcript: transcript),
                      head.runID == initial.runID else {
                    throw HolosError.invalidInput("The speaker labels changed while they were being repaired.")
                }
                if head.sameTranscript { return false }
                let snapshot = try SpeakerSessionSnapshot.load(session: session)
                guard let plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot,
                                                                   to: transcript) else {
                    if head.hasEdits {
                        throw HolosError.invalidInput("The edited speaker labels cannot be kept across the live correction.")
                    }
                    return false
                }
                try Task.checkCancellation()
                try SpeakerTranscriptRetarget.stage(plan, session: session)
                try SpeakerTranscriptRetarget.publishHead(plan, session: session)
                return true
            }
            await archive.releaseLock()
            return repaired
        } catch {
            await archive.releaseLock()
            throw error
        }
    }
}
