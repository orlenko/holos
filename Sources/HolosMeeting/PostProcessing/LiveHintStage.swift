import Foundation
import HolosCore
import HolosSpeakers
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
        /// The fixed head whose unfixed base was used for a late live-hint rebase. The word-fix stage uses its term
        /// and Review-revert marks as evidence when rebuilding automatic fixes during this retry.
        var wordFixedBeforeRebase: Transcript?
    }

    struct SpeakerOutcome {
        var note: String? = nil
        var problem: String? = nil
    }

    private struct IncompletePublication: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Whether an otherwise up-to-date post-processing record must be retried for its saved live hints. A damaged
    /// sidecar, an unmatched text or speaker hint, or an effective speaker rename is pending; a correction already
    /// present and a rename already applied or superseded are settled.
    static func hasPendingWork(session: URL, transcript: Transcript) -> Bool {
        do {
            let hints = try LiveHintStore.read(session: session).hints
            let base = try transcript.fixedFrom.map { try SessionFiles.transcript(id: $0, session: session) }
                ?? transcript
            let text = LiveHints.applyingText(hints, to: base)
            if text.applied > 0 || text.unmatched > 0 { return true }
            guard hints.contains(where: { if case .nameSpeaker = $0.action { true } else { false } }) else {
                return false
            }
            let snapshot = try SpeakerSessionSnapshot.load(session: session)
            guard snapshot.transcript.id == transcript.id, let projection = snapshot.projection else { return true }
            let applied = Set(projection.appliedEditIDs)
            let protected = protectedSpeakers(snapshot.journal.edits, applied: applied, projection: projection)
            let plan = LiveHints.speakerActionPlan(hints, projection: projection, transcript: transcript)
            if plan.unmatched > 0 { return true }
            let proposed = plan.actions
            guard !proposed.isEmpty else { return true }
            return proposed.contains { action in
                guard case .rename(let speakerID, let name) = action,
                      !protected.contains(speakerID) else { return false }
                return projection.speakers.first(where: { $0.id == speakerID })?.name != name
            }
        } catch {
            return true
        }
    }

    /// Speakers a live speaker name must not rename: those an applied `rename` named, and with them every speaker of
    /// their same-name group (`ProjectedSpeaker.memberIDs`), since a rename of any of them reaches all of them
    /// (`SpeakerProjection.fanningOut`) and the one shown may be another than the one renamed.
    static func protectedSpeakers(_ edits: [SpeakerEdit], applied: Set<String>,
                                  projection: SpeakerProjection) -> Set<String> {
        var protected = Set(edits.compactMap { edit -> String? in
            guard applied.contains(edit.id), case .rename(let speakerID, _) = edit.action else { return nil }
            return speakerID
        })
        for speaker in projection.speakers where speaker.memberIDs.contains(where: protected.contains) {
            protected.formUnion(speaker.memberIDs)
        }
        return protected
    }

    static func applyText(session: URL, transcript: Transcript, lease: ProcessingLease) async throws -> TextOutcome {
        let hints: [LiveHint]
        do {
            hints = try LiveHintStore.sealAndRead(session: session).hints
        } catch {
            return TextOutcome(transcript: transcript, hints: [],
                               problem: "Live corrections could not be read: \(error.localizedDescription)")
        }
        // A retry may arrive after an earlier pass fixed words while the sidecar was unreadable. Live hints belong
        // before automatic fixes, so rebase them onto that pass's unfixed revision; the word-fix stage then rebuilds
        // its result from the live-corrected base instead of replacing the new correction from stale `fixedFrom`.
        let base: Transcript
        let wordFixedBeforeRebase: Transcript?
        if let id = transcript.fixedFrom {
            do {
                base = try SessionFiles.transcript(id: id, session: session)
                wordFixedBeforeRebase = transcript
            } catch {
                return TextOutcome(
                    transcript: transcript, hints: hints,
                    problem: "Live corrections could not be rebased onto the transcript before word fixes: "
                        + error.localizedDescription)
            }
        } else {
            base = transcript
            wordFixedBeforeRebase = nil
        }
        let result = LiveHints.applyingText(hints, to: base)
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
        let published = wordFixedBeforeRebase.map {
            WordFixStage.preservingPriorFixes(from: $0, on: result.transcript)
        } ?? result.transcript
        do {
            let labelsPreserved = try await publish(published, liveBase: result.transcript,
                                                    liveSource: base, current: transcript, result: result,
                                                    session: session, lease: lease)
            let text = result.applied == 1 ? "Applied 1 live text correction."
                : "Applied \(result.applied) live text corrections."
            let problem = result.unmatched > 0
                ? "\(result.unmatched) live text \(result.unmatched == 1 ? "correction could" : "corrections could") not be matched to the final transcript."
                : nil
            return TextOutcome(transcript: published, hints: hints, note: text, problem: problem,
                               labelsPreserved: labelsPreserved,
                               wordFixedBeforeRebase: wordFixedBeforeRebase)
        } catch let error where !(error is CancellationError) {
            let incomplete = error is IncompletePublication
            let message = incomplete
                ? "Live text corrections were saved, but their speaker labels could not be published: \(error.localizedDescription)"
                : "Live text corrections could not be saved: \(error.localizedDescription)"
            return TextOutcome(transcript: incomplete ? published : transcript, hints: hints,
                               problem: message, speakerHeadIncomplete: incomplete,
                               wordFixedBeforeRebase: incomplete ? wordFixedBeforeRebase : nil)
        }
    }

    static func applySpeakers(_ hints: [LiveHint], session: URL, transcript: Transcript,
                              profiles: SpeakerProfileStore?) -> SpeakerOutcome {
        guard hints.contains(where: { if case .nameSpeaker = $0.action { true } else { false } }) else {
            return SpeakerOutcome()
        }
        // Planned on the labels as read, outside the speaker lock: when they changed before the save (another
        // window renamed a speaker, joining or leaving a same-name group), the editor refuses the plan, and it is
        // made again, with its protection, on the labels as they are then.
        for attempt in 1...3 {
            let outcome = applySpeakersOnce(hints, session: session, transcript: transcript, profiles: profiles,
                                            retrying: attempt < 3)
            if let outcome { return outcome }
        }
        return SpeakerOutcome(problem: "Live speaker names could not be saved: " + SpeakerEditor.changedMessage)
    }

    /// One plan and save of `applySpeakers`; nil when `retrying` and the editor refused it as made on changed labels.
    private static func applySpeakersOnce(_ hints: [LiveHint], session: URL, transcript: Transcript,
                                          profiles: SpeakerProfileStore?, retrying: Bool) -> SpeakerOutcome? {
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
            let protected = protectedSpeakers(snapshot.journal.edits, applied: applied, projection: projection)
            let plan = LiveHints.speakerActionPlan(hints, projection: projection, transcript: transcript)
            let proposed = plan.actions
            let actions = proposed.filter { action in
                guard case .rename(let speakerID, _) = action else { return true }
                return !protected.contains(speakerID)
            }
            let unmatchedProblem = unmatchedSpeakerProblem(plan.unmatched)
            guard !actions.isEmpty else {
                // An effective rename means this hint was applied before or superseded later; either is complete.
                if !proposed.isEmpty { return SpeakerOutcome(problem: unmatchedProblem) }
                return SpeakerOutcome(problem: unmatchedProblem
                    ?? "Live speaker names could not be matched to the final speaker labels.")
            }
            let changed = try SpeakerEditor.applyUnlessUnchanged(actions, view: projection, session: session,
                                                                 source: "live", regenerateExports: false,
                                                                 profileNames: names, profiles: profiles)
            guard changed != nil else { return SpeakerOutcome(problem: unmatchedProblem) }
            let count = actions.count
            return SpeakerOutcome(note: count == 1 ? "Applied 1 live speaker name."
                                                   : "Applied \(count) live speaker names.",
                                  problem: unmatchedProblem)
        } catch HolosError.unavailable(let message) where retrying && message == SpeakerEditor.changedMessage {
            return nil
        } catch {
            return SpeakerOutcome(problem: "Live speaker names could not be saved: \(error.localizedDescription)")
        }
    }

    private static func publish(_ transcript: Transcript, liveBase: Transcript, liveSource: Transcript,
                                current: Transcript,
                                result: LiveHints.TextOutcome,
                                session: URL, lease: ProcessingLease) async throws -> Bool {
        return try await SessionArchive.withMaintenanceArchive(at: session, lease: lease) { archive in
            try await SessionArchive.withSpeakerLockAsync(at: session) { () async throws -> Bool in
                guard try SessionFiles.currentTranscript(session: session)?.id == current.id else {
                    throw HolosError.unavailable("The transcript changed while live corrections were being saved.")
                }
                var plan: SpeakerTranscriptRetarget.Plan?
                if let head = try SpeakerAnalysis.headState(session: session, transcript: current),
                   head.usableRunID != nil {
                    let snapshot = try SpeakerSessionSnapshot.load(session: session)
                    plan = try SpeakerTranscriptRetarget.plan(session: session, from: snapshot, to: transcript)
                    if head.hasEdits, plan == nil {
                        throw HolosError.invalidInput("The edited speaker labels cannot be kept across the live correction.")
                    }
                }
                try Task.checkCancellation()
                if let plan { try SpeakerTranscriptRetarget.stage(plan, session: session) }
                if transcript.id != liveBase.id {
                    try await archive.saveTranscriptRevision(liveBase)
                    try await archive.recordEvent(kind: MeetingEventKind.liveHintsApplied, details: [
                        "transcriptID": liveBase.id, "base": liveSource.id,
                        "applied": String(result.applied), "unmatched": String(result.unmatched),
                    ])
                }
                try await archive.recordEvent(kind: MeetingEventKind.liveHintsApplied, details: [
                    "transcriptID": transcript.id, "base": current.id,
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
        }
    }

    private static func unmatchedSpeakerProblem(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) live speaker \(count == 1 ? "name could" : "names could") not be matched to the final speaker labels."
    }

    /// Repairs the only incomplete text publication: the corrected transcript is current while its staged speaker
    /// run did not become head. The old head remains a complete snapshot, so the same retarget can be made again.
    private static func repairPreservedHeadIfNeeded(_ transcript: Transcript, session: URL,
                                                    lease: ProcessingLease) async throws -> Bool {
        let initial = try SpeakerAnalysis.headState(session: session, transcript: transcript)
        guard let initial, !initial.sameTranscript, initial.run != nil else { return false }
        return try await SessionArchive.withMaintenanceArchive(at: session, lease: lease) { _ in
            try await SessionArchive.withSpeakerLockAsync(at: session) { () async throws -> Bool in
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
        }
    }
}
