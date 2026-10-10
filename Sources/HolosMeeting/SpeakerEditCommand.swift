import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// A session loaded for a speaker command: its snapshot and the projection selectors resolve against, which is also
/// the view the edit is made on, with the people store and people's current names.
public struct LoadedSpeakers: Sendable {
    public let session: URL
    public let snapshot: SpeakerSessionSnapshot
    public let view: SpeakerProjection
    public let store: SpeakerProfileStore
    /// Profile ID → name.
    public let people: [String: String]
    /// The people store as read when the session was loaded (nil when it could not be read), to tell whether a
    /// change reset the calibration.
    public let peopleBefore: SpeakerProfileDatabase?

    /// Loads `session`'s snapshot with people's current names from `store`; refuses a session without usable speaker
    /// labels (`unavailable`, with the run's problem or how to label it).
    public static func load(session: URL, store: SpeakerProfileStore) throws -> LoadedSpeakers {
        let peopleBefore = try? store.load()
        let people = VoiceProfileService.profileNames(store: store)
        let snapshot = try SpeakerSessionSnapshot.load(
            session: session, profileNames: people,
            applyRecognition: VoiceProfileService.recognitionAllowed(store: store))
        guard let view = snapshot.projection else {
            throw HolosError.unavailable(snapshot.runProblem
                ?? "This meeting has no speaker labels yet. Label them with voiceislocal session diarize \(session.path).")
        }
        return LoadedSpeakers(session: session, snapshot: snapshot, view: view, store: store, people: people,
                              peopleBefore: peopleBefore)
    }
}

/// What `voiceislocal speakers rename|merge|assign|split|exclude|undo|link|me|reject` do (docs/meeting/exports.md
/// §5.7, docs/meeting/people-voice.md §5.9), as a library call: one change saved on the loaded view through `SpeakerEditor` or
/// `VoiceProfileService`, then the exports rewritten and the voice samples learned from this meeting brought in step.
///
/// Rules every change follows:
/// 1. The change is checked against the labels it was worked out on (`LoadedSpeakers.view`) and refused, writing
///    nothing, when they changed meanwhile; a change that would leave the labels as they are is not saved.
/// 2. Once a change is saved, the voice samples it affects are brought in step even when the exports could not be
///    rewritten or the editor failed after saving (a stale sample would hold turns the change moved to someone
///    else, and no later edit would notice); every such failure is reported together as `HolosError.incomplete`.
/// 3. The exports are rewritten after the editor has released the speaker lock.
/// 4. What the command says goes to `report` as it happens, in order: `.output` lines (what was changed) for stdout,
///    `.note` lines (moved-aside exports, removed samples, a reset calibration, label warnings) for stderr. Notes
///    about removed samples and the label warnings are reported before a failure is thrown.
public enum SpeakerEditCommand {
    /// The change to make.
    public enum Change: Sendable, Equatable {
        /// Speaker edits saved as one batch (rename, merge, assign, split, exclude).
        case edit([SpeakerEditAction])
        /// Reverts the view's newest batch.
        case undo
        /// Links a speaker to a person (`VoiceProfileService.link`).
        case link(speakerID: String, to: ProfileTarget, learnVoice: Bool)
        /// "This is me" (`VoiceProfileService.markSelf`).
        case markSelf(speakerID: String, learnVoice: Bool)
        /// "Not <person>" in this meeting (`VoiceProfileService.reject`).
        case reject(speakerID: String, profileID: String)
    }

    public struct Request: Sendable {
        public var loaded: LoadedSpeakers
        public var change: Change

        public init(loaded: LoadedSpeakers, change: Change) {
            self.loaded = loaded; self.change = change
        }
    }

    /// One thing the command says: `.output` is content (stdout), `.note` a message (stderr).
    public enum Message: Sendable, Equatable {
        case output(String)
        case note(String)
    }

    public struct Outcome: Sendable {
        /// False when the labels already looked like that and nothing was saved.
        public var saved: Bool
        /// The session after the change; nil when nothing was saved.
        public var snapshot: SpeakerSessionSnapshot?
    }

    /// `SpeakerEdit.source` of every edit this command saves.
    public static let source = "cli"

    public static let modelsMissing = "Speaker models are not installed, so voices can't be learned. Install them "
        + "with voiceislocal setup --speakers."

    /// Makes the change of `request` (rules 1–4 of the type). `makeExtractor` gives the voice sample extractor for a
    /// session (nil: none can be made, and samples that need recomputing are removed); it is called only when samples
    /// are learned or brought in step. Throws what the editor or the people store refuse, `HolosError.incomplete`
    /// when the change was saved but its follow-up failed, and `CancellationError`.
    public static func run(_ request: Request,
                           makeExtractor: @escaping @Sendable (URL) -> (any VoiceSampleExtractor)?,
                           report: @escaping @Sendable (Message) -> Void) async throws -> Outcome {
        let steps = Steps(loaded: request.loaded, makeExtractor: makeExtractor, report: report)
        switch request.change {
        case .edit(let actions):
            return try await steps.save(actions)
        case .undo:
            return try await steps.undo()
        case .link(let speakerID, let target, let learnVoice):
            return try await steps.link(speakerID: speakerID, learnVoice: learnVoice) { extractor in
                try await VoiceProfileService.link(
                    session: request.loaded.session, speakerID: speakerID, to: target, view: request.loaded.view,
                    learnVoice: learnVoice, extractor: extractor, store: request.loaded.store)
            }
        case .markSelf(let speakerID, let learnVoice):
            return try await steps.link(speakerID: speakerID, learnVoice: learnVoice) { extractor in
                try await VoiceProfileService.markSelf(
                    session: request.loaded.session, speakerID: speakerID, view: request.loaded.view,
                    learnVoice: learnVoice, extractor: extractor, store: request.loaded.store)
            }
        case .reject(let speakerID, let profileID):
            return try await steps.reject(speakerID: speakerID, profileID: profileID)
        }
    }

    /// "Your edited transcript.md was kept as exports/edited-20260923-171200.md."
    public static func movedAsideNote(_ url: URL) -> String {
        "Your edited transcript.\(url.pathExtension) was kept as exports/\(url.lastPathComponent)."
    }

    static let unchangedMessage = "Nothing to change; the speaker labels already look like that."
}

// MARK: - Steps

extension SpeakerEditCommand {
    /// The steps of one run, over the loaded session.
    struct Steps: Sendable {
        let loaded: LoadedSpeakers
        let makeExtractor: @Sendable (URL) -> (any VoiceSampleExtractor)?
        let report: @Sendable (Message) -> Void

        /// Saves one change on the loaded view, says what it did, rewrites the exports, and updates the voice samples
        /// the change affects. A change that would leave the labels as they are is not saved (it would only use up an
        /// undo step); the editor decides that on the current labels under the speaker lock, after refusing a change
        /// whose labels moved on since the load.
        func save(_ actions: [SpeakerEditAction]) async throws -> Outcome {
            let owners = sampleOwners()
            let result: SpeakerEditResult
            do {
                guard let saved = try SpeakerEditor.applyUnlessUnchanged(
                    actions, view: loaded.view, session: loaded.session, source: source, regenerateExports: false,
                    profileNames: loaded.people, profiles: loaded.store) else {
                    report(.output(unchangedMessage))
                    // An earlier run of this same change may have saved its edit and then failed to bring this
                    // meeting's samples in step, which would leave a voiceprint holding speech the edit moved to
                    // someone else. Repeating the change lands here, so the refresh runs from here too; it is decided
                    // by input digests, so it costs nothing when the samples are already in step.
                    // The editor found the current labels as loaded, so the loaded snapshot's warnings still hold.
                    try await finishChange(needsSampleRefresh: true, rewritingExports: false, owners: owners,
                                           diagnostics: loaded.snapshot.diagnostics)
                    return Outcome(saved: false, snapshot: nil)
                }
                result = saved
            } catch HolosError.incomplete(let message) {
                try await refreshAfterSavedChange(HolosError.incomplete(message), owners: owners)
            }
            for action in actions {
                report(.output(describe(action, before: loaded.view, after: result.snapshot.projection,
                                        people: loaded.people)))
            }
            try await finishChange(needsSampleRefresh: result.needsSampleRefresh, rewritingExports: true,
                                   owners: owners,
                                   diagnostics: result.diagnostics.merging(loaded.snapshot.diagnostics))
            return Outcome(saved: true, snapshot: result.snapshot)
        }

        /// Undoes the view's newest batch and says which changes it took back.
        func undo() async throws -> Outcome {
            let undone = newestBatch()
            let owners = sampleOwners()
            let result: SpeakerEditResult
            do {
                result = try SpeakerEditor.undoLast(view: loaded.view, session: loaded.session, source: source,
                                                    regenerateExports: false, profiles: loaded.store)
            } catch HolosError.incomplete(let message) {
                try await refreshAfterSavedChange(HolosError.incomplete(message), owners: owners)
            }
            let descriptions = undone.map {
                describe($0.action, before: loaded.view, after: nil, editID: $0.id, people: loaded.people)
            }
            switch descriptions.count {
            case 0: report(.output("Undid the last speaker change."))
            case 1: report(.output("Undid: \(descriptions[0])"))
            default: report(.output("Undid \(descriptions.count) changes: " + descriptions.joined(separator: " ")))
            }
            // Stale lines the undo would have brought back are reverted with it (SpeakerEditor.undoLast).
            let keptOut = Set(loaded.view.staleEdits.map(\.editID))
                .intersection(result.snapshot.projection?.revertedEditIDs ?? []).count
            if keptOut > 0 {
                report(.note("\(keptOut) earlier speaker \(keptOut == 1 ? "change" : "changes") that could not be "
                             + "applied \(keptOut == 1 ? "stays" : "stay") out of effect; undo does not bring "
                             + "\(keptOut == 1 ? "it" : "them") back."))
            }
            try await finishChange(
                needsSampleRefresh: result.needsSampleRefresh, rewritingExports: true, owners: owners,
                diagnostics: result.diagnostics.merging(loaded.snapshot.diagnostics))
            return Outcome(saved: true, snapshot: result.snapshot)
        }

        /// `speakers link` and `me`: `linking` saves the link (and learns the voice when asked), then this says
        /// what it did. Also without `learnVoice` the extractor is made: a sample the person already has from this
        /// meeting is kept in step.
        func link(speakerID: String, learnVoice: Bool,
                  linking: (_ extractor: (any VoiceSampleExtractor)?) async throws -> SpeakerSessionSnapshot)
            async throws -> Outcome {
            let extractor = makeExtractor(loaded.session)
            let owners = sampleOwners()
            let snapshot: SpeakerSessionSnapshot
            do {
                snapshot = try await linking(extractor)
            } catch {
                noteRemovedSamples(owners)
                throw error
            }
            try reportLink(speakerID: speakerID, snapshot: snapshot, learnVoice: learnVoice,
                           extractorAvailable: extractor != nil)
            noteRemovedSamples(owners)
            return Outcome(saved: true, snapshot: snapshot)
        }

        /// `speakers reject`: "not <person>" in this meeting, then the samples brought in step.
        func reject(speakerID: String, profileID: String) async throws -> Outcome {
            let action = SpeakerEditAction.rejectProfile(speakerID: speakerID, profileID: profileID)
            let owners = sampleOwners()
            let snapshot: SpeakerSessionSnapshot
            do {
                // Whether this changes nothing is decided on the meeting's current labels under the speaker lock,
                // not on the loaded view: another window may have undone the rejection, or linked the speaker to
                // the person, since the load.
                guard let saved = try VoiceProfileService.reject(session: loaded.session, speakerID: speakerID,
                                                                 profileID: profileID, view: loaded.view,
                                                                 store: loaded.store) else {
                    report(.output(unchangedMessage))
                    try await finishChange(needsSampleRefresh: true, rewritingExports: false, owners: owners,
                                           diagnostics: loaded.snapshot.diagnostics)
                    return Outcome(saved: false, snapshot: nil)
                }
                snapshot = saved
            } catch HolosError.incomplete(let message) {
                // Saved, but the exports (rewritten by the editor here) or the reload failed.
                try await refreshAfterSavedChange(HolosError.incomplete(message), owners: owners)
            }
            report(.output(describe(action, before: loaded.view, after: snapshot.projection, people: loaded.people)))
            // A person's sample from this meeting stops using the speaker's turns (a no-op when none is affected).
            try await finishChange(
                needsSampleRefresh: true, rewritingExports: false, owners: owners,
                diagnostics: snapshot.diagnostics.merging(loaded.snapshot.diagnostics))
            return Outcome(saved: true, snapshot: snapshot)
        }

        /// After a saved change: rewrites the exports (when asked), then updates the voice samples the change affects
        /// whether or not the exports could be rewritten (rule 2), notes removed samples, and reports the label notes.
        /// Every failure is reported together as `incomplete`.
        func finishChange(needsSampleRefresh: Bool, rewritingExports: Bool, owners: [String: String],
                          diagnostics: SpeakerSnapshotDiagnostics) async throws {
            var failures: [String] = []
            if rewritingExports {
                do {
                    try rewriteExports()
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            do {
                try await refreshSamplesIfNeeded(needsSampleRefresh)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(error.localizedDescription)
            }
            noteRemovedSamples(owners)
            for note in diagnostics.notes { report(.note(note)) }
            guard failures.isEmpty else { throw HolosError.incomplete(failures.joined(separator: " ")) }
        }

        /// The change was saved, then the editor failed (`incomplete`) before it could say whether samples are
        /// affected: brings this meeting's samples in step anyway, then throws `saved`.
        func refreshAfterSavedChange(_ saved: HolosError, owners: [String: String]) async throws -> Never {
            do {
                try await VoiceProfileService.refreshSamples(
                    afterSaving: saved, session: loaded.session, extractor: makeExtractor(loaded.session),
                    store: loaded.store)
            } catch {
                // `error` here is what the refresh threw, which is the combined report when the samples could not be
                // brought in step, or a cancellation. The parameter is named `saved` so that is plain to read: a
                // `catch` binds `error` itself, and a parameter of that name would be shadowed rather than rethrown.
                noteRemovedSamples(owners)
                throw error
            }
        }

        /// After a saved change that affects a person's voice sample from this meeting, recomputes it (or removes it).
        func refreshSamplesIfNeeded(_ needed: Bool) async throws {
            guard needed else { return }
            do {
                try await VoiceProfileService.refreshSamples(session: loaded.session,
                                                             extractor: makeExtractor(loaded.session),
                                                             store: loaded.store)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw HolosError.incomplete("The change was saved, but a voice sample learned from this meeting could "
                                            + "not be updated: \(error.localizedDescription)")
            }
        }

        /// The people who have a voice sample from this meeting (profile ID → name); empty when the store cannot be
        /// read.
        func sampleOwners() -> [String: String] {
            guard let database = try? loaded.store.load() else { return [:] }
            let sessionID = loaded.snapshot.manifest.id
            return Dictionary(database.profiles.filter { $0.samples.contains { $0.sessionID == sessionID } }
                .map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        }

        /// A note when a sample change reset the calibration (`VoiceProfileService.calibrationResetNote`), then one
        /// for each person in `before` who no longer has a sample from this meeting.
        func noteRemovedSamples(_ before: [String: String]) {
            if let note = VoiceProfileService.calibrationResetNote(before: loaded.peopleBefore,
                                                                   after: try? loaded.store.load()) {
                report(.note(note))
            }
            guard !before.isEmpty else { return }
            let after = sampleOwners()
            for (profileID, name) in before.sorted(by: { $0.value < $1.value }) where after[profileID] == nil {
                report(.note("Removed \(name)'s voice sample from this meeting: the speakers or turns it was learned "
                             + "from changed, and it could not be learned again from the new labels."))
            }
        }

        /// Rewrites exports/ after a change was saved (the editor has released the speaker lock).
        func rewriteExports() throws {
            let session = loaded.session
            let written: ExportWriteResult
            do {
                written = try SessionExports.regenerate(
                    session: session, profileNames: VoiceProfileService.profileNames(store: loaded.store),
                    applyRecognition: VoiceProfileService.recognitionAllowed(store: loaded.store))
            } catch {
                throw HolosError.incomplete("The change was saved, but the exports could not be rewritten: "
                                            + "\(error.localizedDescription) Rewrite them with voiceislocal session "
                                            + "export \(session.path) --all.")
            }
            for url in written.movedAside { report(.note(movedAsideNote(url))) }
        }

        /// Says what `speakers link` or `me` did: the link, and what happened to the voice.
        func reportLink(speakerID: String, snapshot: SpeakerSessionSnapshot, learnVoice: Bool,
                        extractorAvailable: Bool) throws {
            let database = try loaded.store.load()
            // The stored speaker linked, as itself (it may be shown joined with a same-named one).
            let speaker = snapshot.projection?.unjoined.speakers.first { $0.id == speakerID }
            guard let profileID = speaker?.profileID,
                  let profile = database.profiles.first(where: { $0.id == profileID }) else {
                report(.output("Linked \(speakerID)."))
                for note in snapshot.diagnostics.notes { report(.note(note)) }
                return
            }
            report(.output("Linked \(speakerID) to \(profile.displayName)\(profile.isSelf ? " (you)" : "")."))
            if learnVoice {
                report(.note(voiceNote(profile: profile, database: database, snapshot: snapshot,
                                       extractorAvailable: extractorAvailable)))
            }
            for note in snapshot.diagnostics.notes { report(.note(note)) }
        }

        /// The applied lines of the view's newest batch, in journal order (what `undoLast` will revert).
        func newestBatch() -> [SpeakerEdit] {
            guard let batchID = loaded.view.lastUndoableBatchID else { return [] }
            let applied = Set(loaded.view.appliedEditIDs)
            return loaded.snapshot.journal.edits
                .filter { $0.baseRunID == loaded.view.runID && ($0.batchID ?? $0.id) == batchID
                    && applied.contains($0.id) }
        }
    }
}
