import Darwin
import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// Who a speaker is linked to: a known person, or a new one with this name.
public enum ProfileTarget: Sendable, Equatable { case existing(profileID: String), new(name: String) }

/// People and their voices (docs/meeting-design.md §4.10, PR10). The only code that writes profiles and samples.
///
/// Enrollment is asynchronous and the extractor is injected: its real implementations live in
/// HolosDiarization (CLI) or spawn the bundled `holos` (app), and HolosMeeting cannot import FluidAudio.
/// `extractor == nil`, `learnVoice == false`, Remember voices off, or deleted audio → the name/link is
/// recorded and no sample is taken. Journal edits are appended under the speaker lock first; extraction
/// runs after the lock is released; the sample is upserted under `profiles.lock` last.
///
/// Rules that hold for every call:
/// - Linking always creates or links the person, whatever "Remember voices" says, and appends `linkProfile` plus
///   `rename(name: <person's name>)` in one batch, so the meeting keeps the name if the person is later forgotten.
///   Exports are rewritten with the edit (`SpeakerEditor`, current names).
/// - A voiceprint is stored only as a sample of a person the user confirmed, with voice learning requested and
///   "Remember voices" on, and only the confirmed speakers' qualifying turns are ever sent to the extractor. Samples
///   never come from automatic matches.
/// - A person's sample from a meeting is kept in step with that meeting's labels (`refreshSamples`): it is
///   recomputed from the speakers now linked to the person when its inputs changed, and removed when no qualifying
///   turn remains or it can no longer be recomputed (Remember voices off, audio deleted, no extractor, another
///   embedding model), so a stored voiceprint never holds turns the user moved to someone else. A sample built from
///   an earlier run of a meeting that was labelled again is only ever replaced, never removed, by a refresh.
/// - A sample is saved only if the session's speaker generation did not change while it was computed (checked under
///   the speaker lock, then `profiles.lock`); otherwise the work is redone from the new labels, at most 3 times. A
///   refresh never brings back a sample that was forgotten while it ran.
/// - Forgetting writes a tombstone to `forget-journal.jsonl` first, then updates the store, then cleans each affected
///   session under its speaker lock, then marks the tombstone done; `resumePendingForgets` finishes any tombstone a
///   crash left.
public enum VoiceProfileService {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "profiles")

    /// Said when a person was linked with voice learning on in a meeting whose audio was deleted.
    public static let audioDeletedNote = "The recording's audio was deleted, so this voice can't be learned."

    /// How many times a sample computation is redone when the labels change meanwhile.
    static let sampleAttempts = 3

    /// Test hook: while set (a task-local value), called after a forget has updated the profile store and before
    /// it cleans the sessions; a throw stands for a crash there.
    @TaskLocal static var afterForgetStoreUpdate: (@Sendable () throws -> Void)? = nil

    // MARK: - Linking people

    /// Links `speakerID` to a known person or a new one (`to`), then, when `learnVoice` and "Remember voices" is on
    /// and the audio exists, learns or updates that person's sample from this meeting through `extractor`. A person
    /// created here is removed again when the link is refused. Once the link is saved, a failure to update samples
    /// throws `HolosError.incomplete` saying the link was saved.
    public static func link(session: URL, speakerID: String, to target: ProfileTarget, view: SpeakerProjection,
                            learnVoice: Bool, extractor: (any VoiceSampleExtractor)?,
                            store: SpeakerProfileStore) async throws -> SpeakerSessionSnapshot {
        let (profile, created) = try resolve(target, store: store)
        return try await linkPeople([(speakerID, profile)], created: created ? [profile.id] : [], session: session,
                                    view: view, enroll: learnVoice ? [profile.id] : [], extractor: extractor,
                                    store: store)
    }

    /// Links every current suggestion ("Maybe Jim") to its person in one batch, so one undo reverts it, and with
    /// `learnVoices` learns their samples. Refuses (`invalidInput`) a view without suggestions of known people.
    public static func confirmAll(session: URL, view: SpeakerProjection, learnVoices: Bool,
                                  extractor: (any VoiceSampleExtractor)?,
                                  store: SpeakerProfileStore) async throws -> SpeakerSessionSnapshot {
        // The suggestions are recognition decisions on the meeting's labels; with edits missing, they may contradict
        // a link or a "Not Jim" that could not be read. Read here to refuse early, and again under the speaker lock
        // before the lines are appended (`requireCompleteJournal`), where another Holos can no longer slip one in.
        guard try SessionSpeakerStore.readEdits(session: session).isComplete else {
            throw HolosError.unavailable(incompleteEdits)
        }
        let database = try store.load()
        var links: [(String, SpeakerProfile)] = []
        for speaker in view.speakers {
            guard let suggestion = speaker.suggestion,
                  let profile = database.profiles.first(where: { $0.id == suggestion.profileID }) else { continue }
            links.append((speaker.id, profile))
        }
        guard !links.isEmpty else { throw HolosError.invalidInput("There are no suggested names to confirm.") }
        let people = Set(links.map(\.1.id))
        return try await linkPeople(links, created: [], session: session, view: view,
                                    enroll: learnVoices ? people : [], extractor: extractor, store: store,
                                    requireCompleteJournal: true)
    }

    /// "This is me": links `speakerID` to the one `isSelf` person, created on first use with the account's full
    /// name (editable in People). Enrolls a voice sample only when `learnVoice` (the review window's "Learn voices"
    /// box) and "Remember voices" is on; otherwise it only records the link.
    public static func markSelf(session: URL, speakerID: String, view: SpeakerProjection,
                                learnVoice: Bool, extractor: (any VoiceSampleExtractor)?,
                                store: SpeakerProfileStore) async throws -> SpeakerSessionSnapshot {
        let (profile, created) = try store.update { database -> (SpeakerProfile, Bool) in
            if let me = database.profiles.first(where: \.isSelf) { return (me, false) }
            let me = SpeakerProfile(displayName: selfName, isSelf: true, provisional: true)
            database.profiles.append(me)
            return (me, true)
        }
        if created { log.notice("Created the person who is you") }
        return try await linkPeople([(speakerID, profile)], created: created ? [profile.id] : [], session: session,
                                    view: view, enroll: learnVoice ? [profile.id] : [], extractor: extractor,
                                    store: store)
    }

    /// "Not Jim" for this meeting only (`rejectProfile`); unlinks the speaker if it was linked to that person. Takes
    /// no extractor: when the speaker was linked to the person and the person has a sample from this meeting, the
    /// caller then awaits `refreshSamples` (which does nothing when no sample is affected), or, when this throws
    /// `HolosError.incomplete` (the rejection was saved, then reloading or the exports failed),
    /// `refreshSamples(afterSaving:session:extractor:store:)`.
    ///
    /// Nil when the meeting's current labels already say this, decided by the editor under the speaker lock rather
    /// than on the caller's view: another window may have undone this rejection, or linked the speaker to the
    /// person, since the view was made, and reporting success then would leave the match or link in place.
    public static func reject(session: URL, speakerID: String, profileID: String, view: SpeakerProjection,
                              store: SpeakerProfileStore = SpeakerProfileStore()) throws -> SpeakerSessionSnapshot? {
        let result = try SpeakerEditor.applyUnlessUnchanged(
            [.rejectProfile(speakerID: speakerID, profileID: profileID)], view: view, session: session,
            source: editSource, profileNames: profileNames(store: store), profiles: store)
        return result?.snapshot
    }

    /// After an edit in a meeting that contributed samples: recomputes each person's sample from this meeting whose
    /// inputs (linked speakers and their qualifying turns) changed, and removes one when no qualifying turn remains or
    /// it can no longer be recomputed. Samples that are up to date are left alone, so calling it after any edit is
    /// cheap. Throws when an extraction fails (the affected samples are left as they were; removals still happen).
    public static func refreshSamples(session: URL, extractor: (any VoiceSampleExtractor)?,
                                      store: SpeakerProfileStore) async throws {
        try await syncSamples(session: session, extractor: extractor, store: store, enroll: [])
    }

    /// For an edit whose lines were saved but that then failed (`SpeakerEditor` or the caller's export rewrite threw
    /// `HolosError.incomplete`, so `needsSampleRefresh` may never have been seen): brings this meeting's samples in
    /// step as `refreshSamples` does, then throws `error`. When the refresh fails too, its reason is added to the
    /// message. A later unrelated edit would not notice the stale sample, so this must not be skipped.
    public static func refreshSamples(afterSaving error: any Error, session: URL,
                                      extractor: (any VoiceSampleExtractor)?,
                                      store: SpeakerProfileStore) async throws -> Never {
        try await syncAfterSavedEdit(error, session: session, extractor: extractor, store: store, enroll: [])
    }

    private static func syncAfterSavedEdit(_ error: any Error, session: URL, extractor: (any VoiceSampleExtractor)?,
                                           store: SpeakerProfileStore, enroll: Set<String>) async throws -> Never {
        do {
            try await syncSamples(session: session, extractor: extractor, store: store, enroll: enroll)
        } catch is CancellationError {
            throw CancellationError()
        } catch let refresh {
            throw HolosError.incomplete(error.localizedDescription + " A voice sample learned from this meeting "
                                        + "could not be updated either: " + refresh.localizedDescription)
        }
        throw error
    }

    // MARK: - Managing people

    /// Turns "Remember voices" on or off. Off with `forgetExisting` also forgets every sample and every meeting's voice
    /// data (`forgetAll`); names always stay. Returns how many samples were forgotten.
    @discardableResult
    public static func setRemember(_ on: Bool, forgetExisting: Bool, store: SpeakerProfileStore,
                                   sessionsRoot: URL = HolosPaths.sessions) throws -> Int {
        if !on, forgetExisting {
            // The tombstone comes first, and the setting is turned off in the same store write that removes the
            // samples, so a crash or a lock timeout never leaves the setting off with every sample kept and nothing
            // to resume.
            let removed = try forget(store: store, sessionsRoot: sessionsRoot, turnRememberOff: true) { database in
                ForgetRecord(kind: .all, sampleIDs: database.profiles.flatMap(\.samples).map(\.id))
            }
            log.notice("Remember voices turned off")
            return removed
        }
        try store.update { $0.rememberVoices = on }
        log.notice("Remember voices turned \(on ? "on" : "off", privacy: .public)")
        return 0
    }

    /// Turns "Suggest <person> in new meetings" on or off.
    public static func setSuggestions(_ on: Bool, profileID: String, store: SpeakerProfileStore) throws {
        try store.update { database in
            let index = try profileIndex(profileID, in: database)
            database.profiles[index].recognitionEnabled = on
            database.profiles[index].provisional = nil
        }
    }

    /// Renames a person. Meetings keep the names they were given when linked (their own `rename` edits); new
    /// suggestions and links use the new name.
    public static func rename(profileID: String, to name: String, store: SpeakerProfileStore) throws {
        guard let clean = SpeakerEditor.cleanName(name) else { throw HolosError.invalidInput("Give the new name.") }
        try store.update { database in
            let index = try profileIndex(profileID, in: database)
            database.profiles[index].displayName = clean
            database.profiles[index].provisional = nil
        }
    }

    /// Merges person `profileID` into `target` (they are one person): the samples move to `target` (when both have a
    /// sample from one meeting, the one with more speech is kept), `target` keeps its name, and `profileID` is
    /// removed. Refused (`invalidInput`) when both have samples from different embedding models. Meetings keep
    /// their names; a sample that moved stays in step with its meeting as the speakers it was built from.
    ///
    /// A meeting whose recognition result named the person merged away is made to name the person they were merged
    /// into, so the merge does not take the automatic name (or the suggestion) out of that meeting: the projection
    /// drops a match whose person is not in the store, which is what the removal here would otherwise leave behind.
    /// The work across the meetings is journalled first (a `.merge` record in the forget journal, which carries the
    /// two IDs the store no longer holds together), so a crash or a meeting that cannot be written now is finished by
    /// `resumePendingForgets`; this throws `incomplete` when some meeting is left, and the merge itself stands.
    /// A `stored` line is appended only once the store write has committed, and nothing is retargeted without it:
    /// the record is written before that write, so a merge refused there (two people whose samples come from
    /// different speaker models) or lost to a crash must not have the meetings pointed anywhere. A resume that
    /// finds no `stored` line therefore drops the record, and those meetings keep naming whoever they named.
    public static func merge(profileID: String, into target: String, store: SpeakerProfileStore,
                             sessionsRoot: URL = HolosPaths.sessions) throws {
        guard profileID != target else { throw HolosError.invalidInput("Choose two different people to merge.") }
        // A forget of either person that has been listed but not yet written must not have its work moved out from
        // under it: it removes the samples it listed, and one learned since and moved by this merge would survive
        // on the other person. Checked again inside the merge's own locked write, which the forget's write takes.
        let names = { (record: ForgetRecord) in
            record.kind == .profile && (record.profileID == profileID || record.profileID == target)
        }
        guard try !store.pendingForgets().contains(where: names) else {
            throw HolosError.unavailable("One of these people is being forgotten; try the merge again in a moment.")
        }
        // A forget of a newer Holos is not in that list, and it may have listed one of these people: moving a
        // sample between them would put it where the IDs that forget listed will never reach it.
        guard try !store.forgetJournalHasUnreadableLines() else {
            throw HolosError.unavailable("A newer Holos is forgetting voices; merge these people once it has "
                                         + "finished.")
        }
        let record = ForgetRecord(kind: .merge, profileID: profileID, targetProfileID: target)
        try store.appendForgetRecord(record)
        try store.update { database in
            guard try !store.pendingForgets().contains(where: names) else {
                throw HolosError.unavailable("One of these people is being forgotten; try the merge again in a "
                                             + "moment.")
            }
            // Both questions again, under this write's own hold of the lock: the outer check released it, and a
            // newer Holos can have appended its tombstone in between, readable or not.
            guard try !store.forgetJournalHasUnreadableLines() else {
                throw HolosError.unavailable("A newer Holos is forgetting voices; merge these people once it has "
                                             + "finished.")
            }
            let fromIndex = try profileIndex(profileID, in: database)
            let intoIndex = try profileIndex(target, in: database)
            let from = database.profiles[fromIndex]
            var into = database.profiles[intoIndex]
            if !from.samples.isEmpty, !into.samples.isEmpty, from.embeddingModel != into.embeddingModel {
                throw HolosError.invalidInput("These two people have voice samples from different speaker models, "
                                              + "so they can't be merged. Forget one person's samples first.")
            }
            for sample in from.samples {
                if let index = into.samples.firstIndex(where: { $0.sessionID == sample.sessionID }) {
                    if sample.speechSeconds > into.samples[index].speechSeconds { into.samples[index] = sample }
                } else {
                    into.samples.append(sample)
                }
            }
            if into.embeddingModel == nil { into.embeddingModel = from.embeddingModel }
            if into.samples.isEmpty { into.embeddingModel = nil }
            // The target is taken up by this merge whether or not anything about them changes (a person with no
            // samples can leave every field as it was), so a link that is refused later must not take them back.
            // What removed this person, recorded in the write that removes them: a journal record beside a missing
            // person cannot say whether this merge, a forget, or another merge took them away.
            database.mergedInto = (database.mergedInto ?? [:]).merging([profileID: target]) { _, new in new }
            into.provisional = nil
            into.isSelf = into.isSelf || from.isSelf
            into.createdAt = min(into.createdAt, from.createdAt)
            into.lastUsedAt = max(into.lastUsedAt, from.lastUsedAt)
            database.profiles[intoIndex] = into
            database.profiles.remove(at: fromIndex)
        }
        try store.appendForgetRecord(.stored(record.id))
        log.notice("Merged two people")
        try retargetMeetings(record, store: store, sessionsRoot: sessionsRoot)
    }

    /// Points every meeting's recognition results at the person `record` was merged into, under each meeting's
    /// speaker lock, and rewrites the exports of those that changed (they show the names recognition gave). Each
    /// step is idempotent: a meeting that already names the target is left untouched. A meeting that cannot be
    /// written now leaves the record pending, and this throws `incomplete`.
    private static func retargetMeetings(_ record: ForgetRecord, store: SpeakerProfileStore,
                                         sessionsRoot: URL) throws {
        guard let from = record.profileID, var to = record.targetProfileID else { return }
        let database = try store.load()
        if try store.storedForget(record.id) == nil {
            // No marker: the store write either never committed (the merge was refused, or the process went before
            // it) or committed and the process went before the marker. The database says which, because the write
            // that removes the person records what removed them: a person a forget or another merge took away is
            // not this merge's doing, however absent they are.
            guard database.mergedInto?[from] == to else {
                log.notice("Dropped a merge whose store write never happened")
                try store.appendForgetRecord(.done(record.id))
                return
            }
            // It did commit; write the marker the crash cost it and carry on with the meetings.
            try store.appendForgetRecord(.stored(record.id))
        }
        // Another window may have merged the person this one was merged into onwards while this record waited.
        // Writing the ID it named then would point the meetings at somebody who is no longer there, and a
        // projection drops a match whose person is not in the store, which is the very loss this pass prevents.
        // Only merges the database records as committed are followed: a refused one changed nothing.
        to = Self.mergedOnwards(to, in: database)
        guard database.profiles.contains(where: { $0.id == to }) else {
            log.notice("Dropped a merge whose target is no longer in the store")
            try store.appendForgetRecord(.done(record.id))
            return
        }
        var failed = 0
        for session in try sessionFolders(sessionsRoot) {
            do {
                // The destination is resolved again for each meeting, from the store as it is then: another window
                // can merge it onwards while this pass runs, and the meetings it has not reached yet must name
                // where that person is now, not where they were when this pass started.
                try retarget(from: from, session: session, store: store)
            } catch {
                failed += 1
                log.error("Cannot point a meeting at the person two people were merged into yet: \(ProcessSpawner.logCategory(error), privacy: .public)")
            }
        }
        guard failed == 0 else {
            throw HolosError.incomplete("The people were merged, but \(failed) \(failed == 1 ? "meeting" : "meetings") "
                                        + "could not be updated yet; Holos finishes this next time. Until then they "
                                        + "show no automatic name for that person.")
        }
        try store.appendForgetRecord(.done(record.id))
    }

    /// Where `profileID` ended up, following the merges the store records as committed (`A -> B`, then `B -> C`
    /// gives `C`). Stops at the first ID no committed merge names, and after `mergeChainLimit` steps, so a store a
    /// newer Holos wrote cannot send this round a cycle.
    static func mergedOnwards(_ profileID: String, in database: SpeakerProfileDatabase) -> String {
        guard let merged = database.mergedInto else { return profileID }
        var current = profileID
        var seen: Set<String> = [current]
        // No count to stop at: the map is finite and every step takes an ID out of it, so `seen` ends the walk,
        // and a person merged onwards more often than any fixed number would still have to be found.
        while let next = merged[current], seen.insert(next).inserted { current = next }
        return current
    }

    /// One meeting's recognition results, retargeted under its speaker lock, and then its generated exports.
    ///
    /// A merge is not a forget, so nothing here deletes what it cannot interpret: a recognition result that cannot
    /// be read (damaged, or written by a newer Holos) is thrown, which keeps the merge record pending instead of
    /// leaving that result naming a person who no longer exists. The Holos that can read it finishes the record.
    /// A meeting with no manifest is not a meeting and is skipped.
    ///
    /// The exports are rewritten for every meeting that has recognition results and generated exports, not only
    /// for the ones this run changed: a retry finds them already retargeted, and `changed` would then say the
    /// rewrite is not owed although it never happened. `SessionExports.regenerate` writes only the files that
    /// differ from what it renders, so repeating it costs a render and no writes.
    private static func retarget(from: String, session: URL, store: SpeakerProfileStore) throws {
        // A folder with no manifest is not a meeting and is skipped; one whose manifest cannot be read now is,
        // so the read throws and the merge stays pending for a run that can read it.
        var info = stat()
        if lstat(SessionPaths.manifest(session).path, &info) != 0 {
            // Only a manifest that is not there says "not a meeting". A folder that cannot be inspected right now
            // (no traversal permission, an I/O error) has not been visited, so the merge waits for it.
            let code = errno
            guard code == ENOENT || code == ENOTDIR else {
                throw HolosError.io("Cannot inspect a meeting folder: \(String(cString: strerror(code))).")
            }
            return
        }
        // A manifest that is there but is not a file is damage, not an absent one: the meeting is left pending.
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw HolosError.invalidInput("A meeting's manifest.json is not a regular file.")
        }
        _ = try SessionArchive.readManifest(at: session)
        let hadRecognition = try SessionArchive.withSpeakerLock(at: session) { () throws -> Bool in
            let to = Self.mergedOnwards(from, in: try store.load())
            guard to != from else { return false }
            let map = [from: to]
            let files = try SessionSpeakerStore.recognitionFiles(session: session)
            // A kill during an atomic write leaves one of Holos's own `.<token>.tmp` files behind, and nothing
            // else clears this folder; without this the merge would wait for it for ever. No recognition write is
            // in flight under this lock, so such a file belongs to nobody.
            var unknown = files.other
            if unknown, try SessionSpeakerStore.purgeRecognitionLeftovers(session: session) {
                unknown = try SessionSpeakerStore.recognitionFiles(session: session).other
            }
            // An entry this build still does not know may be a recognition result of a newer Holos that names the
            // person merged away. A merge deletes nothing, so the meeting is left for a build that can read it.
            guard !unknown else {
                throw HolosError.unavailable("This meeting holds recognition results a newer Holos wrote; they are "
                                             + "left as they are until that Holos runs.")
            }
            for runID in files.runIDs {
                guard var result = try SessionSpeakerStore.readRecognition(runID: runID, session: session),
                      result.retargetProfiles(map) else { continue }
                try SessionSpeakerStore.writeRecognition(result, session: session)
            }
            return !files.runIDs.isEmpty
        }
        guard hadRecognition, try hasGeneratedExports(session) else { return }
        // "Remember voices" alone, for the same reason as a forget's rewrite: this meeting's results are correct
        // by now, and an unrelated unfinished forget must not cost it every automatic name for good. One throwing
        // read, so a store that cannot be read keeps the merge pending instead of writing exports with no names.
        let database = try store.load()
        let names = Dictionary(database.profiles.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        try SessionExports.regenerate(session: session, profileNames: names,
                                      applyRecognition: database.rememberVoices)
    }

    /// `holos people calibrate --apply`: computes the thresholds inside the store's locked update, from the samples
    /// present when they are saved (never from an earlier read, which another window or command may have changed by
    /// then), and stores them with the embedding model they were measured on; they apply only to runs of that model.
    /// Refused (`invalidInput`) when the samples come from more than one embedding model, or below the §4.10
    /// minimums.
    @discardableResult
    public static func applyCalibration(store: SpeakerProfileStore) throws -> RecognitionCalibration.Calibration {
        let calibration = try store.update { database throws -> RecognitionCalibration.Calibration in
            let models = RecognitionCalibration.models(database)
            guard models.count <= 1 else {
                throw HolosError.invalidInput(
                    "Voice samples come from \(models.count) speaker models, whose distances can't be compared. "
                        + "Forget the samples of the older model, then calibrate again.")
            }
            guard let calibration = RecognitionCalibration.calibration(database: database) else {
                let measured = models.first.map { RecognitionCalibration.distances(database: database, model: $0) }
                throw HolosError.invalidInput(
                    "Calibration needs voice samples from at least \(RecognitionCalibration.minimumMeetings) "
                        + "meetings and at least \(RecognitionCalibration.minimumRepeatedPeople) people with "
                        + "samples from 2 or more meetings; there are \(measured?.meetings ?? 0) and "
                        + "\(measured?.repeatedPeople ?? 0).")
            }
            database.calibratedThresholds = calibration.thresholds
            database.calibratedModel = calibration.model
            database.calibrationResetAt = nil
            return calibration
        }
        log.notice("Saved calibrated recognition thresholds")
        return calibration
    }

    /// Said when a change to the voice samples reset the calibration (`SpeakerProfileStore.update` clears it in the
    /// same write that changes the samples).
    public static let calibrationResetNote = "The voice samples changed, so the calibration was reset: new meetings "
        + "only suggest names, and name nobody automatically, until you calibrate again (holos people calibrate "
        + "--apply)."

    /// `calibrationResetNote` when `before` (read before a change) was calibrated and `after` was reset since then,
    /// else nil.
    public static func calibrationResetNote(before: SpeakerProfileDatabase?,
                                            after: SpeakerProfileDatabase?) -> String? {
        guard let before, let after, before.isCalibrated, after.calibratedThresholds == nil,
              let reset = after.calibrationResetAt, reset != before.calibrationResetAt else { return nil }
        return calibrationResetNote
    }

    // MARK: - Forgetting

    // Each forget lists what it removes in its tombstone from an unlocked read, then its store write (under
    // `profiles.lock`) removes what matches its scope at that moment (`perform`). Each returns how many samples that
    // write removed, so callers report what was forgotten, not the earlier listing.

    /// Forgets one voice sample, and removes that person's entries from its meeting's evaluation voice data.
    @discardableResult
    public static func forget(sampleID: String, store: SpeakerProfileStore,
                              sessionsRoot: URL = HolosPaths.sessions) throws -> Int {
        return try forget(store: store, sessionsRoot: sessionsRoot) { database in
            guard let profile = database.profiles.first(where: { $0.samples.contains { $0.id == sampleID } }),
                  let sample = profile.samples.first(where: { $0.id == sampleID }) else {
                throw HolosError.invalidInput("There is no voice sample \(sampleID).")
            }
            return ForgetRecord(kind: .sample, profileID: profile.id, sampleIDs: [sampleID],
                                sessionIDs: [sample.sessionID])
        }
    }

    /// Forgets a person: their name and every sample. Meetings keep the name they were given; every reference to the
    /// person is removed from the recognition results, and their entries from the evaluation voice data, of every
    /// meeting in `sessionsRoot` (a session kept in another folder is not visited), and the exports of meetings whose
    /// recognition named them are rewritten.
    @discardableResult
    public static func forget(profileID: String, store: SpeakerProfileStore,
                              sessionsRoot: URL = HolosPaths.sessions) throws -> Int {
        return try forget(store: store, sessionsRoot: sessionsRoot) { database in
            guard let profile = database.profiles.first(where: { $0.id == profileID }) else {
                throw HolosError.invalidInput("There is no person \(profileID).")
            }
            return ForgetRecord(kind: .profile, profileID: profileID, sampleIDs: profile.samples.map(\.id),
                                sessionIDs: unique(profile.samples.map(\.sessionID)))
        }
    }

    /// Forgets the samples learned from one meeting (Delete Meeting's "Also forget voice samples"). Names stay.
    @discardableResult
    public static func forget(sessionID: String, store: SpeakerProfileStore) throws -> Int {
        return try forget(store: store, sessionsRoot: HolosPaths.sessions) { database in
            let samples = database.profiles.flatMap(\.samples).filter { $0.sessionID == sessionID }
            return ForgetRecord(kind: .session, sampleIDs: samples.map(\.id), sessionIDs: [sessionID])
        }
    }

    /// "Forget All Voices": every sample, and the voice data and recognition results of every meeting in
    /// `sessionsRoot` (a session kept in another folder is not visited); names stay.
    @discardableResult
    public static func forgetAll(store: SpeakerProfileStore, sessionsRoot: URL = HolosPaths.sessions) throws -> Int {
        return try forget(store: store, sessionsRoot: sessionsRoot) { database in
            ForgetRecord(kind: .all, sampleIDs: database.profiles.flatMap(\.samples).map(\.id))
        }
    }

    /// Finishes every forget a crash left pending (app launch; the start of every `holos people`, `speakers`, and
    /// `session` command). Each step is idempotent. When all are finished the journal is compacted. Throws
    /// `HolosError.incomplete` when some meeting could not be cleaned yet (it is retried next time).
    public static func resumePendingForgets(store: SpeakerProfileStore,
                                            sessionsRoot: URL = HolosPaths.sessions) throws {
        guard !(try store.forgetRecords()).isEmpty else { return }
        let pending = try store.pendingForgets()
        var failed = 0
        for record in pending {
            do {
                if record.kind == .merge {
                    try retargetMeetings(record, store: store, sessionsRoot: sessionsRoot)
                } else {
                    try perform(record, store: store, sessionsRoot: sessionsRoot)
                }
                log.notice("Finished a pending forget (\(record.kind?.rawValue ?? "?", privacy: .public))")
            } catch {
                failed += 1
                log.error("A pending forget is still unfinished: \(ProcessSpawner.logCategory(error), privacy: .public)")
            }
        }
        guard failed == 0 else {
            throw HolosError.incomplete("An earlier request to forget voices is not finished yet; Holos retries it "
                                        + "next time.")
        }
        try store.compactForgetJournal()
    }

    // MARK: - Reading people

    /// Current names, for SpeakerProjection.make(profileNames:). Empty (and logged) when the store cannot be read.
    public static func profileNames(store: SpeakerProfileStore = SpeakerProfileStore()) -> [String: String] {
        do {
            return Dictionary(try store.load().profiles.map { ($0.id, $0.displayName) },
                              uniquingKeysWith: { first, _ in first })
        } catch {
            log.error("Cannot read people: \(ProcessSpawner.logCategory(error), privacy: .public)")
            return [:]
        }
    }

    /// Whether a meeting's stored recognition result may be applied: "Remember voices" is on, and no forget still
    /// has meetings whose voice data or recognition results it has not reached (including a forget this build
    /// cannot read). A forget that only owes an exported transcript does not hold recognition back: nothing Holos
    /// reads names the forgotten person any more. Off means kept
    /// samples are not used, which is what the People window promises when the setting is turned off without
    /// forgetting them, so no suggestion or automatic name is shown or exported until it is turned back on
    /// (nothing is deleted). False when the store cannot be read, like the empty `profileNames` there: with the
    /// people unreadable, a name recognition chose earlier is not shown either.
    public static func recognitionAllowed(store: SpeakerProfileStore = SpeakerProfileStore()) -> Bool {
        do {
            guard try store.load().rememberVoices else { return false }
            // One read of the journal for all three questions: this runs on every reload of a meeting's labels and
            // every export, and asking them separately read and decoded the same file up to four times.
            //
            // A forget whose store write is done but whose meetings are not cleaned yet (a crash, or a meeting
            // that could not be written) leaves recognition results naming people it was meant to remove, and
            // `resumePendingForgets` finishes them in the background. Until it does, those results are not used:
            // a name the user asked Holos to forget must not be shown or exported in the meantime. A line this
            // build cannot read may be a newer Holos's unfinished forget, which it can neither resume nor account
            // for.
            let forgets = try store.forgetState()
            guard !forgets.unreadable else { return false }
            return forgets.pending.allSatisfy { $0.kind == .merge || forgets.isCleaned($0.id) }
        } catch {
            log.error("Cannot read whether voices are remembered: \(ProcessSpawner.logCategory(error), privacy: .public)")
            return false
        }
    }

    /// Most recently used first; for the review window's name combo box. Empty (and logged) when the store cannot
    /// be read.
    public static func knownPeople(store: SpeakerProfileStore = SpeakerProfileStore()) -> [SpeakerProfile] {
        do {
            return sortedPeople(try store.load().profiles)
        } catch {
            log.error("Cannot read people: \(ProcessSpawner.logCategory(error), privacy: .public)")
            return []
        }
    }

    /// Most recently used first, then by name, then by ID.
    public static func sortedPeople(_ profiles: [SpeakerProfile]) -> [SpeakerProfile] {
        profiles.sorted { left, right in
            if left.lastUsedAt != right.lastUsedAt { return left.lastUsedAt > right.lastUsedAt }
            switch left.displayName.localizedCaseInsensitiveCompare(right.displayName) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return left.id < right.id
            }
        }
    }

    /// `holos people export`: names and sample metadata as JSON (format `holos-people`), with each sample's embedding
    /// only when `includeVoiceprints`.
    public static func exportPeople(store: SpeakerProfileStore, includeVoiceprints: Bool,
                                    now: Date = Date()) throws -> Data {
        let database = try store.load()
        let export = PeopleExport(
            exportedAt: now, rememberVoices: database.rememberVoices,
            calibrated: database.isCalibrated,
            people: sortedPeople(database.profiles).map { profile in
                PeopleExport.Person(
                    id: profile.id, name: profile.displayName, isSelf: profile.isSelf, createdAt: profile.createdAt,
                    lastUsedAt: profile.lastUsedAt, suggestions: profile.recognitionEnabled,
                    embeddingModel: profile.embeddingModel,
                    samples: profile.samples.map { sample in
                        PeopleExport.Sample(
                            id: sample.id, sessionID: sample.sessionID, sessionName: sample.sessionName,
                            speakerIDs: sample.speakerIDs, speechSeconds: sample.speechSeconds,
                            condition: sample.condition, weak: sample.weak,
                            droppedOutlierTurns: sample.droppedOutlierTurns, addedAt: sample.addedAt,
                            embedding: includeVoiceprints ? sample.embedding : nil)
                    })
            })
        return try HolosJSON.encoder().encode(export)
    }

    // MARK: - Linking (shared)

    /// `SpeakerEdit.source` for edits made here: "app" inside an app bundle, else "cli".
    static var editSource: String { Bundle.main.bundleURL.pathExtension == "app" ? "app" : "cli" }

    /// The name of the person who is you on first use.
    static var selfName: String { SpeakerEditor.cleanName(NSFullUserName()) ?? "Me" }

    private static func resolve(_ target: ProfileTarget, store: SpeakerProfileStore) throws -> (SpeakerProfile, Bool) {
        switch target {
        case .existing(let profileID):
            let database = try store.load()
            return (database.profiles[try profileIndex(profileID, in: database)], false)
        case .new(let name):
            guard let clean = SpeakerEditor.cleanName(name) else {
                throw HolosError.invalidInput("A new person needs a name.")
            }
            let profile = SpeakerProfile(displayName: clean, provisional: true)
            try store.update { $0.profiles.append(profile) }
            return (profile, true)
        }
    }

    /// Appends `linkProfile` + `rename` for every link in one batch, marking the people used in the locked step that
    /// appends them (`SpeakerEditor.claimPeople`), then updates samples.
    ///
    /// A batch the view says changes nothing appends no line, so it is checked against the meeting's current labels
    /// under its speaker lock instead: another window may have changed this speaker's link or name since the view was
    /// made, and reporting success then would silently hand back that other window's link. The people are checked and
    /// marked used in the same locked step, so this path saves nothing behind a person who is gone either.
    private static func linkPeople(_ links: [(speakerID: String, profile: SpeakerProfile)], created: Set<String>,
                                   session: URL, view: SpeakerProjection, enroll: Set<String>,
                                   extractor: (any VoiceSampleExtractor)?, store: SpeakerProfileStore,
                                   requireCompleteJournal: Bool = false) async throws -> SpeakerSessionSnapshot {
        let actions = links.flatMap { link -> [SpeakerEditAction] in
            [.linkProfile(speakerID: link.speakerID, profileID: link.profile.id),
             .rename(speakerID: link.speakerID, name: link.profile.displayName)]
        }
        let linked = Dictionary(links.map { ($0.profile.id, $0.profile.displayName) },
                                uniquingKeysWith: { first, _ in first })
        var snapshot: SpeakerSessionSnapshot
        var needsRefresh = false
        do {
            if SpeakerEditor.changesNothing(actions, on: view) {
                snapshot = try SessionArchive.withSpeakerLock(at: session) { () throws -> SpeakerSessionSnapshot in
                    let current = try SpeakerSessionSnapshot.load(
                        session: session, profileNames: profileNames(store: store),
                        applyRecognition: recognitionAllowed(store: store))
                    guard let projection = current.projection, projection.runID == view.runID,
                          SpeakerEditor.changesNothing(actions, on: projection) else {
                        throw HolosError.unavailable(SpeakerEditor.changedMessage)
                    }
                    try SpeakerEditor.claimPeople(linked, createdHere: created, profiles: store, at: Date())
                    return current
                }
                // An earlier run of this same link may have saved its lines and then failed to bring the samples
                // in step, which would leave a voiceprint holding turns now linked to somebody else. Repeating the
                // command lands here, so the refresh runs from here too; it is decided by input digests, so it
                // costs nothing when they are already in step.
                needsRefresh = true
            } else {
                let result = try SpeakerEditor.apply(actions, view: view, session: session, source: editSource,
                                                     profileNames: profileNames(store: store), profiles: store,
                                                     requirePeople: linked, createdHere: created,
                                                     requireCompleteJournal: requireCompleteJournal)
                snapshot = result.snapshot
                needsRefresh = result.needsSampleRefresh
            }
        } catch {
            guard editsWereSaved(error) else {
                rollBack(created, store: store)
                throw error
            }
            // The link is saved, so the people this call created are taken up before anything else: the path
            // below always rethrows, and leaving them marked unfinished would have the launch sweep remove a
            // person the meeting links. Then samples are brought in step anyway (cheap when nothing changed),
            // and the error is reported.
            takeUp(created, named: linked, store: store)
            try await syncAfterSavedEdit(error, session: session, extractor: extractor, store: store, enroll: enroll)
        }
        takeUp(created, named: linked, store: store)
        guard !enroll.isEmpty || needsRefresh else { return snapshot }
        do {
            try await syncSamples(session: session, extractor: extractor, store: store, enroll: enroll)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HolosError.incomplete("The name was saved, but the voice could not be learned: "
                                        + error.localizedDescription)
        }
        return snapshot
    }

    /// Marks the people this call created as no longer a link that might not happen, once its lines are appended:
    /// what keeps the launch sweep and a later rollback off them (`SpeakerEditor.claimPeople` leaves a call's own
    /// creations alone until here). Idempotent, so every path that saved lines can call it. A failure is retried
    /// once and then said out loud: it leaves a person the sweep would take back in an hour, and any later rename,
    /// merge, suggestions setting or link of them clears it first.
    private static func takeUp(_ created: Set<String>, named: [String: String], store: SpeakerProfileStore) {
        guard !created.isEmpty else { return }
        let take = { try SpeakerEditor.claimPeople(named.filter { created.contains($0.key) }, profiles: store,
                                                   at: Date()) }
        do {
            try take()
        } catch {
            do { try take() } catch {
                log.error("The link was saved, but the person it created is still marked unfinished: \(ProcessSpawner.logCategory(error), privacy: .public)")
            }
        }
    }

    /// Takes back the people this call created, after the link they were created for was refused.
    ///
    /// A person is removed only while nobody has taken them up: no samples, and still `provisional`, the state a
    /// person is created with here and that the locked step of a saved link clears (`SpeakerEditor.claimPeople`)
    /// before its lines are appended. So a person another window has linked in another meeting between this call
    /// creating them and its own link being refused is kept: removing them would leave that meeting pointing at
    /// nobody. An explicit state is what makes that sound; `lastUsedAt` cannot, since `HolosJSON` stores dates to
    /// the second and both windows can be inside one. A refusal after the claim (the lines could not be appended)
    /// leaves the person in the list, where the user can forget them; that is the harmless direction.
    static func rollBack(_ created: Set<String>, store: SpeakerProfileStore) {
        guard !created.isEmpty else { return }
        do {
            try store.update { database in
                database.profiles.removeAll { profile in
                    created.contains(profile.id) && profile.samples.isEmpty && profile.provisional == true
                }
            }
        } catch {
            log.error("Cannot remove a person whose link was refused: \(ProcessSpawner.logCategory(error), privacy: .public)")
        }
    }

    /// `SpeakerEditor` throws `incomplete` once its lines are saved (only reloading or rewriting the exports failed),
    /// so a person created for the link must be kept.
    private static func editsWereSaved(_ error: any Error) -> Bool {
        if case .incomplete? = error as? HolosError { return true }
        return false
    }

    // MARK: - Samples (shared)

    /// What one person's sample from this meeting needs.
    private struct SamplePlan: Equatable {
        enum Action { case remove, extract }
        let profileID: String
        let existing: VoiceprintSample?
        let speakerIDs: [String]
        let turns: [ProjectedTurn]
        let digest: String
        let action: Action
        /// The existing sample stays when the new labels give no sample (it was built from another run; see `plan`).
        let keepWhenUnlearnable: Bool
    }

    private enum SampleChange {
        /// Removes the sample `sampleID` (the one the plan saw).
        case remove(profileID: String, sampleID: String)
        /// Adds the sample, or replaces the one the plan saw (`replacing`). A refresh (`replacing` set) whose sample
        /// is gone or was replaced meanwhile (forgotten, or learned again) is dropped, so it never brings a forgotten
        /// sample back.
        case upsert(profileID: String, sample: VoiceprintSample, replacing: String?)
    }

    /// Said when a forget removed the voices this work would have saved, while it was being computed. The forget is
    /// the later request, so nothing is saved and the work is not tried again: trying again would put back what the
    /// user has just asked Holos to forget.
    static let forgottenWhileLearning = "Voices were forgotten while this one was being learned, so nothing was "
        + "saved. Learn it again if you still want to."

    /// Said when the labels or the people's samples kept changing while samples were computed.
    static let labelsKeptChanging = "The speaker labels or voice samples kept changing while the voice was learned; "
        + "try again."

    /// Said when a meeting's edit journal has a torn or unreadable line: no voice is learned from its labels, and its
    /// suggestions are neither shown nor confirmed.
    public static let incompleteEdits = "Some speaker changes in this meeting can't be read (damaged, cut off while "
        + "saving, or saved by a newer Holos), so Holos doesn't learn voices from it or use its voice suggestions. "
        + "Its saved voice samples are left as they are. If you use a newer Holos elsewhere, update this one."

    /// Brings every person's sample from this meeting in step with its labels, and learns samples for `enroll`.
    /// Runs up to `sampleAttempts` times when the labels, or the store's inputs to the plan, change while it works;
    /// then leaves the samples and throws `unavailable`. Without usable labels it leaves the samples as they are, and
    /// throws `unavailable` when a voice was to be learned (`enroll`). When the edit journal is incomplete (a torn or
    /// unreadable line: the labels may miss a link, a rejection, or a reassignment), nothing is learned, recomputed,
    /// or removed, and `unavailable` (`incompleteEdits`) is thrown when there was anything to do (a voice to learn,
    /// or a sample from this meeting to keep in step).
    ///
    /// The plan is made from an unlocked read of the store; the changes are published only if, under the speaker lock
    /// and then `profiles.lock`, the generation is unchanged and the store as it is then gives the same plan (and the
    /// same minimum sample length). Otherwise the attempt is redone from the new state.
    static func syncSamples(session: URL, extractor: (any VoiceSampleExtractor)?, store: SpeakerProfileStore,
                            enroll: Set<String>) async throws {
        for attempt in 1...sampleAttempts {
            try Task.checkCancellation()
            let (generation, snapshot) = try consistentSnapshot(session)
            let sessionID = snapshot.manifest.id
            guard snapshot.journal.isComplete else {
                let hasSample = try store.load().profiles.contains { $0.samples.contains { $0.sessionID == sessionID } }
                guard enroll.isEmpty, !hasSample else {
                    log.error("Session \(sessionID, privacy: .public): speaker edits cannot all be read; voice samples left as they are")
                    throw HolosError.unavailable(incompleteEdits)
                }
                return
            }
            guard let run = snapshot.run, let projection = snapshot.projection else {
                log.notice("Session \(sessionID, privacy: .public): no usable speaker labels; voice samples left as they are")
                guard enroll.isEmpty else {
                    throw HolosError.unavailable(snapshot.runProblem
                        ?? "This meeting has no usable speaker labels, so no voice can be learned from it.")
                }
                return
            }
            let model = run.engine?.embeddingModel
            let database = try store.load()
            let forgetEpoch = database.forgetEpoch ?? 0
            let makePlans = { (database: SpeakerProfileDatabase) in
                plan(database: database, snapshot: snapshot, run: run, projection: projection, enroll: enroll,
                     extractorAvailable: extractor != nil)
            }
            let plans = makePlans(database)
            guard !plans.isEmpty else { return }

            // Extraction runs with no lock held, for the planned turns only.
            var embeddings: [String: TurnEmbedding] = [:]
            var extractionError: (any Error)?
            let wanted = plans.filter { $0.action == .extract }
            if let extractor, !wanted.isEmpty {
                do {
                    embeddings = try await extract(wanted, session: session, extractor: extractor)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    extractionError = error
                }
            }
            let minimumSeconds = { (database: SpeakerProfileDatabase) in
                SpeakerRecognizer.thresholds(database, model: model).thresholds.minSampleSeconds
            }
            let minimum = minimumSeconds(database)
            var changes: [SampleChange] = []
            for plan in plans {
                switch plan.action {
                case .remove:
                    if let existing = plan.existing {
                        changes.append(.remove(profileID: plan.profileID, sampleID: existing.id))
                    }
                case .extract:
                    guard extractionError == nil else { continue }
                    let turnEmbeddings = plan.turns.compactMap { embeddings[$0.id] }
                    guard let result = VoiceEnrollment.sample(for: plan.speakerIDs, projection: projection, run: run,
                                                              turnEmbeddings: turnEmbeddings,
                                                              minSampleSeconds: minimum) else {
                        if let existing = plan.existing, !plan.keepWhenUnlearnable {
                            changes.append(.remove(profileID: plan.profileID, sampleID: existing.id))
                        }
                        continue
                    }
                    let sample = VoiceprintSample(
                        id: plan.existing?.id ?? UUID().uuidString, sessionID: snapshot.manifest.id,
                        sessionName: snapshot.manifest.name, speakerIDs: plan.speakerIDs,
                        speechSeconds: result.speechSeconds, embedding: result.vector, condition: result.condition,
                        weak: result.weak, droppedOutlierTurns: result.droppedOutlierTurns,
                        addedAt: plan.existing?.addedAt ?? Date(), generation: generation, inputDigest: plan.digest)
                    changes.append(.upsert(profileID: plan.profileID, sample: sample, replacing: plan.existing?.id))
                }
            }

            // Publish only if the labels are still the ones the samples were computed from (§1.7 order), and the
            // store still gives the same plan: a sample forgotten, refreshed, merged, or learned elsewhere meanwhile,
            // a person forgotten, Remember voices or the calibration changed, all make the work stale.
            var forgotten = false
            let published = try SessionArchive.withSpeakerLock(at: session) { () throws -> Bool in
                guard try SessionSpeakerStore.generation(session: session) == generation else { return false }
                return try store.update { current -> Bool in
                    // A forget that landed while this was computed wins: it was the later request, and the samples
                    // alone cannot show it when the person had none from this meeting either way.
                    guard (current.forgetEpoch ?? 0) == forgetEpoch else {
                        forgotten = true
                        return false
                    }
                    guard makePlans(current) == plans, minimumSeconds(current) == minimum else { return false }
                    apply(changes, to: &current, sessionID: sessionID, model: model)
                    return true
                }
            }
            if forgotten {
                log.notice("Session \(sessionID, privacy: .public): voices were forgotten while a voice sample was computed; nothing was saved")
                // A refresh keeps what the forget did and says nothing: it had nothing of its own to save. A voice
                // the user asked to learn is reported, because they asked for it and it is not there.
                guard enroll.isEmpty else { throw HolosError.unavailable(forgottenWhileLearning) }
                return
            }
            if published {
                let upserts = changes.filter { if case .upsert = $0 { true } else { false } }.count
                log.info("Session \(sessionID, privacy: .public): \(upserts, privacy: .public) voice samples saved, \(changes.count - upserts, privacy: .public) removed")
                if let extractionError { throw extractionError }
                return
            }
            log.notice("Session \(sessionID, privacy: .public): speaker labels or voice samples changed while voice samples were computed (attempt \(attempt, privacy: .public)); computing again")
        }
        log.error("Speaker labels kept changing; voice samples were left as they were after \(sampleAttempts, privacy: .public) attempts")
        throw HolosError.unavailable(labelsKeptChanging)
    }

    /// The generation and the snapshot loaded while it held (read under the speaker lock before and after the load,
    /// so the lock is held only for the two readings).
    private static func consistentSnapshot(_ session: URL) throws -> (String?, SpeakerSessionSnapshot) {
        let generation = { try SessionArchive.withSpeakerLock(at: session) {
            try SessionSpeakerStore.generation(session: session)
        } }
        for _ in 1...sampleAttempts {
            let before = try generation()
            let snapshot = try SpeakerSessionSnapshot.load(session: session)
            if try generation() == before { return (before, snapshot) }
        }
        throw HolosError.unavailable("Speaker labels are being changed; try again.")
    }

    /// Which samples need work: each person with a sample from this meeting, plus `enroll`. Up-to-date samples
    /// (same input digest) need nothing.
    ///
    /// A sample built from the head run whose inputs changed is recomputed, or removed when it cannot be (no
    /// qualifying turn left, Remember voices off, audio deleted, no extractor, another model): the change may have
    /// moved a turn it holds to someone else. A sample built from an earlier run (the meeting was labelled again) is
    /// different: that run can no longer be edited, so its turns are still the ones the user confirmed. It is replaced
    /// only by a sample learned from the new labels, and otherwise kept.
    private static func plan(database: SpeakerProfileDatabase, snapshot: SpeakerSessionSnapshot, run: DiarizationRun,
                             projection: SpeakerProjection, enroll: Set<String>,
                             extractorAvailable: Bool) -> [SamplePlan] {
        let sessionID = snapshot.manifest.id
        let known = Set(database.profiles.map(\.id))
        let model = run.engine?.embeddingModel
        var plans: [SamplePlan] = []
        for profile in database.profiles {
            let existing = profile.samples.first { $0.sessionID == sessionID }
            guard existing != nil || enroll.contains(profile.id) else { continue }
            let speakerIDs = linkedSpeakers(profile.id, sample: existing, projection: projection,
                                            database: database)
            let digest = VoiceEnrollment.inputDigest(speakerIDs: speakerIDs, projection: projection)
            if let existing, existing.inputDigest == digest { continue }
            let fromEarlierRun = existing.map { builtFromEarlierRun($0, headRunID: run.id) } ?? false
            let turns = VoiceEnrollment.candidateTurns(for: speakerIDs, projection: projection)
            let canLearn = database.rememberVoices && !snapshot.audioDeleted && extractorAvailable && model != nil
                && (profile.embeddingModel == nil || profile.embeddingModel == model)
            let action: SamplePlan.Action
            if speakerIDs.isEmpty || turns.isEmpty || !canLearn {
                guard existing != nil, !fromEarlierRun else { continue }
                action = .remove
            } else {
                action = .extract
            }
            plans.append(SamplePlan(profileID: profile.id, existing: existing, speakerIDs: speakerIDs, turns: turns,
                                    digest: digest, action: action, keepWhenUnlearnable: fromEarlierRun))
        }
        return plans
    }

    /// Whether `sample` was computed from a run other than the head (its generation names another run ID).
    static func builtFromEarlierRun(_ sample: VoiceprintSample, headRunID: String) -> Bool {
        guard let generation = sample.generation,
              let separator = generation.lastIndex(of: ":") else { return false }
        return generation[..<separator] != headRunID
    }

    /// The meeting's speakers linked to `profileID`, plus the speakers `sample` was built from whose link names the
    /// person this one was merged from (`mergedInto` says so, and the sample moved with them).
    ///
    /// Only a merge the store records lets an unknown link count: a speaker relinked to somebody else who was then
    /// forgotten also names a person the store no longer holds, and reading that as "still this person's" kept a
    /// voiceprint alive under the wrong one, with a digest that never changed to say so.
    static func linkedSpeakers(_ profileID: String, sample: VoiceprintSample?, projection: SpeakerProjection,
                               database: SpeakerProfileDatabase) -> [String] {
        let built = Set(sample?.speakerIDs ?? [])
        return projection.speakers.filter { speaker in
            guard let linked = speaker.profileID else { return false }
            if linked == profileID { return true }
            guard built.contains(speaker.id), !database.profiles.contains(where: { $0.id == linked }) else {
                return false
            }
            return mergedOnwards(linked, in: database) == profileID
        }.map(\.id)
    }

    /// The embeddings of every planned turn, one extractor call per track; only requested turns are kept.
    private static func extract(_ plans: [SamplePlan], session: URL,
                                extractor: any VoiceSampleExtractor) async throws -> [String: TurnEmbedding] {
        var byTrack: [String: [TurnRef]] = [:]
        var requested = Set<String>()
        for plan in plans {
            for turn in plan.turns where requested.insert(turn.id).inserted {
                byTrack[turn.track, default: []].append(TurnRef(turn))
            }
        }
        var embeddings: [String: TurnEmbedding] = [:]
        for track in byTrack.keys.sorted() {
            try Task.checkCancellation()
            for embedding in try await extractor.turnEmbeddings(session: session, track: track,
                                                                turns: byTrack[track] ?? [])
            where requested.contains(embedding.turnID) && embeddings[embedding.turnID] == nil {
                embeddings[embedding.turnID] = embedding
            }
        }
        return embeddings
    }

    /// Applies sample changes for one meeting to the database (caller holds the speaker lock, then `profiles.lock`,
    /// and the generation is the one the changes were computed from, so no newer sample can be overwritten). A person
    /// forgotten meanwhile is skipped; nothing is added once "Remember voices" was turned off, or to a person whose
    /// samples are of another model. A refresh of a sample that was forgotten (or replaced) meanwhile is dropped: a
    /// forget never touches the speaker generation, so this check is what keeps a forgotten sample from coming back.
    private static func apply(_ changes: [SampleChange], to database: inout SpeakerProfileDatabase, sessionID: String,
                              model: EmbeddingModelID?) {
        for change in changes {
            switch change {
            case .remove(let profileID, let sampleID):
                guard let index = database.profiles.firstIndex(where: { $0.id == profileID }) else { continue }
                database.profiles[index].samples.removeAll { $0.id == sampleID }
                if database.profiles[index].samples.isEmpty { database.profiles[index].embeddingModel = nil }
            case .upsert(let profileID, var sample, let replacing):
                guard database.rememberVoices, let model,
                      let index = database.profiles.firstIndex(where: { $0.id == profileID }) else { continue }
                var profile = database.profiles[index]
                if let current = profile.embeddingModel, current != model, !profile.samples.isEmpty { continue }
                if let at = profile.samples.firstIndex(where: { $0.sessionID == sessionID }) {
                    let existing = profile.samples[at]
                    if let replacing, existing.id != replacing { continue }
                    sample.id = existing.id
                    sample.addedAt = existing.addedAt
                    profile.samples[at] = sample
                } else {
                    guard replacing == nil else { continue }
                    profile.samples.append(sample)
                }
                profile.embeddingModel = model
                database.profiles[index] = profile
            }
        }
    }

    /// Whether an edit from `before` to `after` changed the inputs of a sample some person has from this meeting
    /// (`SpeakerEditor` sets `needsSampleRefresh` from it). True when the store cannot be read.
    static func samplesAffected(before: SpeakerProjection, after: SpeakerProjection, sessionID: String,
                                store: SpeakerProfileStore) -> Bool {
        let database: SpeakerProfileDatabase
        do {
            database = try store.load()
        } catch {
            log.error("Cannot read people to check voice samples: \(ProcessSpawner.logCategory(error), privacy: .public)")
            return true
        }
        let known = Set(database.profiles.map(\.id))
        for profile in database.profiles {
            guard let sample = profile.samples.first(where: { $0.sessionID == sessionID }) else { continue }
            let old = linkedSpeakers(profile.id, sample: sample, projection: before, database: database)
            let new = linkedSpeakers(profile.id, sample: sample, projection: after, database: database)
            if VoiceEnrollment.inputDigest(speakerIDs: old, projection: before)
                != VoiceEnrollment.inputDigest(speakerIDs: new, projection: after) {
                return true
            }
        }
        return false
    }

    // MARK: - Forgetting (shared)

    /// Writes the tombstone, then performs it. `turnRememberOff` is recorded in the tombstone and turns "Remember
    /// voices" off in the store write that removes the samples; it is applied only while that write is still owed
    /// (no `stored` line yet), so a forget that keeps failing on a meeting cannot undo the user turning the setting
    /// back on. Returns how many samples its store write removed.
    private static func forget(store: SpeakerProfileStore, sessionsRoot: URL, turnRememberOff: Bool = false,
                               listing: @escaping (SpeakerProfileDatabase) throws -> ForgetRecord) throws -> Int {
        // The listing and the tombstone are one locked step: between them, a merge could move a sample the listing
        // did not see to somebody else, where the IDs this tombstone carries would never reach it, and a merge
        // that starts after it is refused while this forget is unfinished.
        guard let record = try store.appendForgetRecord(listing: { database in
            var record = try listing(database)
            record.turnRememberOff = turnRememberOff ? true : nil
            return record
        }) else { return 0 }
        let removed = try perform(record, store: store, sessionsRoot: sessionsRoot)
        log.notice("Forgot voices (\(record.kind?.rawValue ?? "?", privacy: .public))")
        return removed
    }

    /// The steps of one forget, each idempotent: the store, its `stored` line, then the sessions, then the `done`
    /// line. The `done` line is written only when every place the forgotten data could be was cleaned; otherwise this
    /// throws and the tombstone stays pending.
    ///
    /// Which phase this run is in comes from the journal, not from the caller, so a crash before the store write is
    /// told apart from a crash after it. While the store write is still owed (no `stored` line for the tombstone),
    /// it turns "Remember voices" off when the tombstone asked for that, and it removes every sample the scope covers
    /// in the store as it is at that write (its linearization point), so a sample learned or moved between the
    /// listing and the write is removed too: `.all` every sample, `.session` every sample from the tombstone's
    /// meetings. Once the `stored` line is there, a later run removes only the samples the tombstone lists (and, for
    /// `.profile`, the person, on every run), so it never removes one learned after the user turned "Remember voices"
    /// back on or linked the meeting again, and never turns the setting off a second time. A crash between the store
    /// write and its `stored` line makes the next run sweep once more, which forgets a little more than it had to,
    /// never less.
    ///
    /// The `stored` line also records the person the meetings are cleaned of: for a `.sample` forget, the one the
    /// store write found the sample under, which a merge may have changed since the tombstone was written.
    /// Returns how many samples the store write removed.
    @discardableResult
    static func perform(_ record: ForgetRecord, store: SpeakerProfileStore, sessionsRoot: URL) throws -> Int {
        guard let kind = record.kind, kind != .merge else { return 0 }
        // Only a tombstone the journal still holds as unfinished is performed. Replaying one that is done, or that
        // compaction has taken away with its `done` line, must change nothing at all.
        guard try store.pendingForgets().contains(where: { $0.id == record.id }) else { return 0 }
        let sampleIDs = Set(record.sampleIDs ?? [])
        let sessionIDs = Set(record.sessionIDs ?? [])
        let stored = try store.storedForget(record.id)
        var removed = 0
        /// The person the meetings are cleaned of. The tombstone's until the store write finds the samples under
        /// someone else (a merge since it was written), and then that person's.
        var owner = stored?.profileID ?? record.profileID
        if stored == nil {
            var found: String?
            removed = try store.update { database -> Int in
                let before = database.sampleCount
                if record.turnRememberOff == true { database.rememberVoices = false }
                if kind == .profile, let profileID = record.profileID {
                    database.profiles.removeAll { $0.id == profileID }
                }
                // The person the samples are under now, read in the write that removes them: a merge since the
                // tombstone was written moves them to the person it was merged into, and the meetings are then
                // cleaned of that person. Both scopes that name a person need this; `.session` and `.all` clean
                // every meeting whole and name nobody.
                if kind == .sample || kind == .profile {
                    found = database.profiles.first { $0.samples.contains { sampleIDs.contains($0.id) } }?.id
                }
                let inScope: (VoiceprintSample) -> Bool = { sample in
                    switch kind {
                    case .all: return true
                    case .session: return sessionIDs.contains(sample.sessionID)
                    case .profile, .sample, .merge: return false
                    }
                }
                for index in database.profiles.indices {
                    database.profiles[index].samples.removeAll { sampleIDs.contains($0.id) || inScope($0) }
                    if database.profiles[index].samples.isEmpty { database.profiles[index].embeddingModel = nil }
                }
                // Voice sample work that started before this write must not publish after it (`syncSamples`),
                // whether or not there was anything to remove yet: a voice being learned right now is exactly what
                // a forget of this scope is meant to stop.
                database.forgetEpoch = (database.forgetEpoch ?? 0) + 1
                return before - database.sampleCount
            }
            owner = found ?? owner
            try store.appendForgetRecord(.stored(record.id, profileID: owner))
        }
        // An interrupted atomic write of the store leaves a whole copy of it, voiceprints and all, beside it.
        try store.purgeTemporaryFiles()
        try afterForgetStoreUpdate?()

        var sessions: [URL] = []
        switch kind {
        case .profile, .all:
            // A root that cannot be listed (other than one that does not exist) throws, so the forget stays pending.
            sessions = try sessionFolders(sessionsRoot)
        case .sample:
            sessions = try (record.sessionIDs ?? []).compactMap { try sessionFolder($0, root: sessionsRoot) }
        case .session, .merge:
            sessions = []
        }
        var failed = 0
        var owed: [URL] = []
        for session in sessions {
            do {
                if try scrub(session, kind: kind, profileID: owner, store: store) { owed.append(session) }
            } catch {
                failed += 1
                log.error("Cannot remove forgotten voices from a meeting yet: \(ProcessSpawner.logCategory(error), privacy: .public)")
            }
        }
        if failed == 0, try !store.forgetIsCleaned(record.id) {
            // Nothing Holos reads names the forgotten person any more, so recognition need not wait on whatever is
            // still owed (`recognitionAllowed`). Written before the exports are rewritten, so those rewrites see
            // the meetings as they are now and keep every name this forget does not touch.
            try store.appendForgetRecord(.cleaned(record.id))
        }
        var exportsOwed = 0
        for session in owed {
            do {
                try rewriteExports(session, store: store)
            } catch {
                exportsOwed += 1
                log.error("Cannot rewrite a meeting's exports after a forget yet: \(ProcessSpawner.logCategory(error), privacy: .public)")
            }
        }
        guard failed == 0, exportsOwed == 0 else {
            let count = failed + exportsOwed
            throw HolosError.incomplete("The voices were forgotten, but \(count) \(count == 1 ? "meeting" : "meetings") "
                                        + "could not be cleaned up yet; Holos finishes this next time.")
        }
        try store.appendForgetRecord(.done(record.id))
        return removed
    }

    /// Removes what a forget leaves in one meeting, under its speaker lock: every voice file and recognition result
    /// (`.all`), or every reference to the person in recognition results (`.profile`) and the person's speakers'
    /// entries in evaluation voice files (`.profile`, `.sample`). The person's entries are those linked to them, or
    /// to someone no longer in the store (merged into them, or forgotten earlier). Whatever cannot be checked for the
    /// person is deleted with the rest of its folder: a recognition or voice file that cannot be read (damaged, or
    /// from a newer Holos), an unexpected entry in those folders, voice data whose run, transcript, or edit journal
    /// cannot be fully read, and every voice file (and, for `.profile`, recognition result) of a meeting whose
    /// manifest cannot be read. Anything that cannot be listed or deleted throws, so the forget stays pending.
    ///
    /// Rewrites the meeting's generated exports afterwards, because they show the names recognition gave, and throws
    /// when that fails, so the tombstone stays pending and the next run writes them. Whether the rewrite is owed
    /// cannot be read from the recognition file, which this run has already scrubbed: `.profile` keeps its
    /// recognition results, so a meeting that has them is rewritten on every run until it succeeds; `.all` deletes
    /// them, so every meeting whose exports Holos generated is rewritten. `.sample` and `.session` change no name and
    /// rewrite nothing. The rewrite itself is idempotent: it writes only the files that differ from what it renders.
    private static func scrub(_ session: URL, kind: ForgetRecord.Kind, profileID: String?,
                              store: SpeakerProfileStore) throws -> Bool {
        do {
            _ = try SessionArchive.readManifest(at: session)
        } catch {
            // The voice data goes now, because it cannot be told apart without the manifest. The exports cannot be
            // rewritten without it either, and they may still hold a name this forget removes, so they stay owed:
            // a repaired manifest is rewritten at the next launch.
            if try SessionSpeakerStore.purgeVoiceFolders(session: session, recognition: kind != .sample) {
                log.error("Deleted the voice data of a meeting whose manifest cannot be read: \(ProcessSpawner.logCategory(error), privacy: .public)")
            }
            guard kind == .profile || kind == .all else { return false }
            return try hasGeneratedExports(session)
        }
        _ = try SessionArchive.withSpeakerLock(at: session) { () throws -> Bool in
            let recognition = try SessionSpeakerStore.recognitionFiles(session: session)
            if kind == .all {
                // Unreadable files are deleted like the others, without being read first.
                try SessionSpeakerStore.deleteVoiceData(session: session)
                try SessionSpeakerStore.deleteRecognition(session: session)
                return !recognition.runIDs.isEmpty || recognition.other
            }
            guard let profileID else { return false }
            // Like recognition (`RecognizeStage`), the rewrite is made from the people read under `profiles.lock`,
            // held until it is written (taken after the speaker lock, the §1.7 order), so no store change lands in
            // between.
            return try store.withLockedDatabase { database -> Bool in
                let known = Set(database.profiles.map(\.id))
                let isThePerson: (String?) -> Bool = { linked in
                    guard let linked else { return false }
                    if linked == profileID { return true }
                    guard !known.contains(linked) else { return false }
                    // A link naming somebody the store no longer holds is this person's, because a merge moves
                    // the samples and leaves the meeting's link as it was. Unless the store says where that
                    // person went: a merge still retargeting its meetings has links that belong to whoever they
                    // were merged into, and a forget of anybody else must leave them alone.
                    let moved = Self.mergedOnwards(linked, in: database)
                    return moved == profileID || !known.contains(moved)
                }
                // The voice data goes first, while the recognition results are still there: a speaker the meeting
                // names only through a `likely` match has no link, and the labels alone would not know whose it
                // is. Each run is read with its own result, so the projection applies that run's matches, its
                // rejections and its links, and says who each speaker is now.
                let voice = try SessionSpeakerStore.voiceDataFiles(session: session)
                if voice.other {
                    log.error("Deleted a meeting's voice data that holds unexpected files")
                    try SessionSpeakerStore.deleteVoiceData(session: session)
                } else {
                    for runID in voice.runIDs {
                        guard try removeVoiceEntries(isThePerson, runID: runID, session: session,
                                                     forgotten: kind == .profile ? profileID : nil,
                                                     names: database) else { break }
                    }
                }
                if kind == .profile {
                    _ = try removeMatches(isThePerson, files: recognition, session: session)
                }
                return !recognition.runIDs.isEmpty || recognition.other
            }
        }
        // Owed on every run, not only when this one found recognition results: a previous attempt may have
        // scrubbed or deleted the very files that would say a rewrite is still due.
        guard kind == .all || kind == .profile else { return false }
        return try hasGeneratedExports(session)
    }

    /// Whether the meeting has exports Holos generated. Only their absence says no: a marker that cannot be
    /// inspected right now (no traversal permission, an I/O error) is thrown, so the forget stays pending rather
    /// than finishing over an exported transcript that may still hold the name.
    private static func hasGeneratedExports(_ session: URL) throws -> Bool {
        var generated = stat()
        if lstat(SessionPaths.generatedExports(session).path, &generated) != 0 {
            let code = errno
            guard code == ENOENT || code == ENOTDIR else {
                throw HolosError.io("Cannot inspect a meeting's exports: \(String(cString: strerror(code))).")
            }
            return false
        }
        // Present but not a file is damage, not an absence: the operation waits rather than finishing over an
        // exported transcript it cannot rewrite.
        guard (generated.st_mode & S_IFMT) == S_IFREG else {
            throw HolosError.invalidInput("A meeting's exports/.generated.json is not a regular file.")
        }
        return true
    }

    /// Rewrites one meeting's generated exports after a forget has scrubbed every meeting, so the names they show
    /// are the ones that survive it: the people who were forgotten are gone from the recognition results by now,
    /// and `recognitionAllowed` no longer holds this forget against them, so everybody else keeps their name.
    private static func rewriteExports(_ session: URL, store: SpeakerProfileStore) throws {
        // "Remember voices" alone, not `recognitionAllowed`: this forget has scrubbed every meeting by now, so
        // what it removed is gone, and another forget still on its way must not make these exports lose every
        // other person's automatic name for good. A meeting that still holds a name that other forget removes is
        // rewritten again when it reaches it; those two forgets each rewrite what they clean.
        //
        // One throwing read, not `try?` and `profileNames`: a store that cannot be read right now would otherwise
        // look like no names and no recognition, and these exports would be written without a single automatic
        // name and the forget marked done over them.
        let database = try store.load()
        let names = Dictionary(database.profiles.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        try SessionExports.regenerate(session: session, profileNames: names,
                                      applyRecognition: database.rememberVoices)
    }

    /// A file written by a newer Holos (`unavailable`), which `SessionFiles.isDamage` leaves out so that nothing
    /// overwrites it. Voice data is the one place that is not enough: its owner cannot be told without those
    /// labels, and leaving it would keep a person's voiceprints behind a finished forget, so it goes with the rest.
    /// A transient failure (`io`) is not this and still propagates, so the forget waits and tries again.
    private static func isFromANewerHolos(_ error: any Error) -> Bool {
        if case .unavailable? = error as? HolosError { return true }
        return false
    }

    /// Removes every reference to the person (`isThePerson`: matches, merge suggestions, skipped people; one helper,
    /// `RecognitionResult.removeProfiles`) from every recognition result in `files` (caller holds the speaker lock).
    /// When one cannot be read, or the folder holds an unexpected entry, the meeting's recognition results are
    /// deleted instead. Returns whether anything changed.
    private static func removeMatches(_ isThePerson: (String?) -> Bool, files: (runIDs: [String], other: Bool),
                                      session: URL) throws -> Bool {
        if files.other {
            log.error("Deleted a meeting's recognition results that hold unexpected files")
            try SessionSpeakerStore.deleteRecognition(session: session)
            return true
        }
        var changed = false
        for runID in files.runIDs {
            let read: RecognitionResult?
            do {
                read = try SessionSpeakerStore.readRecognition(runID: runID, session: session)
            } catch {
                log.error("Deleted a meeting's recognition results that cannot be read: \(ProcessSpawner.logCategory(error), privacy: .public)")
                try SessionSpeakerStore.deleteRecognition(session: session)
                return true
            }
            guard var result = read else { continue }
            if result.removeProfiles(where: { isThePerson($0) }) {
                try SessionSpeakerStore.writeRecognition(result, session: session)
                changed = true
            }
        }
        return changed
    }

    /// Removes the centroids and turn embeddings of the person's speakers (`isThePerson` of their link) from the
    /// evaluation voice file of one run (caller holds the speaker lock). Nothing to do without a voice file. When a
    /// turn of theirs was won by a cluster that is not one of their speaker's (the user reassigned it, or moved it to
    /// a speaker they made), that cluster's centroid holds their voice and cannot be told apart from the rest of the
    /// cluster's, so the meeting's voice data is deleted instead. When the voice file cannot be read (damaged, or from a newer Holos), or its run, transcript, or edit journal cannot be
    /// read in full (a damaged, newer, or torn journal line may be the person's link), so the person's entries cannot
    /// be told apart, the meeting's voice data is deleted instead. Returns false once the voice data was deleted (the
    /// other runs have nothing left).
    private static func removeVoiceEntries(_ isThePerson: (String?) -> Bool, runID: String, session: URL,
                                           forgotten: String? = nil,
                                           names: SpeakerProfileDatabase = SpeakerProfileDatabase()) throws -> Bool {
        let read: SessionVoiceData?
        do {
            read = try SessionSpeakerStore.readVoiceData(runID: runID, session: session)
        } catch {
            log.error("Deleted a meeting's voice data that cannot be read: \(ProcessSpawner.logCategory(error), privacy: .public)")
            try SessionSpeakerStore.deleteVoiceData(session: session)
            return false
        }
        guard var voice = read else { return true }
        let projection: SpeakerProjection
        do {
            let run = try SessionSpeakerStore.readRun(id: runID, session: session)
            let transcript = try SessionFiles.transcript(id: run.transcriptID, session: session)
            let journal = try SessionSpeakerStore.readEdits(session: session)
            guard journal.isComplete else {
                log.error("Deleted a meeting's voice data whose speaker edits cannot all be read")
                try SessionSpeakerStore.deleteVoiceData(session: session)
                return false
            }
            // The run's own result, so a speaker this meeting names automatically counts as that person, while a
            // "Not Jim", a link to somebody else and an explicit name all take it back, exactly as the meeting
            // shows it. A result that cannot be read leaves that undecidable, so the voice data goes.
            var recognition: RecognitionResult?
            if forgotten != nil {
                do {
                    recognition = try SessionSpeakerStore.readRecognition(runID: runID, session: session)
                } catch {
                    log.error("Deleted a meeting's voice data whose recognition result cannot be read")
                    try SessionSpeakerStore.deleteVoiceData(session: session)
                    return false
                }
            }
            // The forgotten person is out of the store by now, so their name is put back for this reading only:
            // `SpeakerProjection` applies a match only for a person it has a name for.
            var profileNames = Dictionary(names.profiles.map { ($0.id, $0.displayName) },
                                          uniquingKeysWith: { first, _ in first })
            if let forgotten { profileNames[forgotten] = profileNames[forgotten] ?? "(forgotten)" }
            projection = SpeakerProjection.make(run: run, transcript: transcript, edits: journal.edits,
                                                recognition: recognition, profileNames: profileNames)
        } catch let error where SessionFiles.isDamage(error) || Self.isFromANewerHolos(error) {
            log.error("Deleted a meeting's voice data whose speaker labels cannot be read")
            try SessionSpeakerStore.deleteVoiceData(session: session)
            return false
        }
        // The effective person, not just the link: a speaker this meeting names automatically is theirs too, and
        // a rejection, a link to somebody else or an explicit name has already taken that back.
        let speakers = projection.speakers.filter { isThePerson($0.effectiveProfileID) }
        let speakerIDs = Set(speakers.map(\.id))
        let clusters = Set(speakers.flatMap(\.clusterIDs))
        let spoken = projection.turns.filter { $0.speakerID.map(speakerIDs.contains) ?? false }
        let turns = Set(spoken.map { String($0.id.prefix { $0 != "/" }) })
        // A centroid is the machine's average of its cluster's speech. When the user moved a turn of this person to
        // a speaker that does not own its cluster (a reassignment, or a speaker the user made), that cluster's
        // centroid still holds this person's voice while the cluster is not one of theirs, so it survives the filter
        // below. It cannot be recomputed here, so the meeting's voice data goes instead of a centroid that still
        // mixes in a forgotten person.
        if spoken.contains(where: { turn in turn.clusterID.map { !clusters.contains($0) } ?? false }) {
            log.error("Deleted a meeting's voice data whose centroids still hold a forgotten person's speech")
            try SessionSpeakerStore.deleteVoiceData(session: session)
            return false
        }
        let centroids = voice.centroids.filter { !clusters.contains($0.key) }
        let embeddings = voice.turnEmbeddings.filter { !turns.contains($0.turnID) }
        guard centroids.count != voice.centroids.count || embeddings.count != voice.turnEmbeddings.count else {
            return true
        }
        voice.centroids = centroids
        voice.turnEmbeddings = embeddings
        try SessionSpeakerStore.writeVoiceData(voice, session: session)
        return true
    }

    /// The `.holos` folders directly in `root` (not links), sorted by name. Empty when `root` does not exist; any
    /// other failure to list it, or to inspect an entry, is thrown (a forget must not take it for "no meetings").
    static func sessionFolders(_ root: URL) throws -> [URL] {
        var info = stat()
        if stat(root.path, &info) != 0 {
            let code = errno
            if code == ENOENT { return [] }
            throw HolosError.io("Cannot open the meetings folder: \(String(cString: strerror(code))).")
        }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        } catch {
            throw HolosError.io("Cannot list the meetings folder: \(error.localizedDescription)")
        }
        return try names.filter { $0.hasSuffix(".holos") && !$0.hasPrefix(".") }.sorted().compactMap {
            try sessionFolder(url: root.appendingPathComponent($0, isDirectory: true))
        }
    }

    /// `<root>/<SESSION-ID>.holos` when it is a folder; nil when it does not exist (or is not a folder).
    private static func sessionFolder(_ sessionID: String, root: URL) throws -> URL? {
        guard SessionArchive.validToken(sessionID) else { return nil }
        return try sessionFolder(url: root.appendingPathComponent("\(sessionID).holos", isDirectory: true))
    }

    private static func sessionFolder(url: URL) throws -> URL? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return nil }
            throw HolosError.io("Cannot inspect a meeting folder: \(String(cString: strerror(code))).")
        }
        return (info.st_mode & S_IFMT) == S_IFDIR ? url : nil
    }

    // MARK: - Helpers

    private static func profileIndex(_ profileID: String, in database: SpeakerProfileDatabase) throws -> Int {
        guard let index = database.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw HolosError.invalidInput("There is no person \(profileID); list people with holos people list.")
        }
        return index
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

/// `holos people export` (format `holos-people`, schema 1). Embeddings only with `--include-voiceprints`.
struct PeopleExport: Encodable {
    struct Sample: Encodable {
        var id: String
        var sessionID: String
        var sessionName: String
        var speakerIDs: [String]
        var speechSeconds: Double
        var condition: RecordingCondition
        var weak: Bool
        var droppedOutlierTurns: Int
        var addedAt: Date
        var embedding: FloatVector?
    }

    struct Person: Encodable {
        var id: String
        var name: String
        var isSelf: Bool
        var createdAt: Date
        var lastUsedAt: Date
        var suggestions: Bool
        var embeddingModel: EmbeddingModelID?
        var samples: [Sample]
    }

    var schemaVersion = 1
    var format = "holos-people"
    var exportedAt: Date
    var rememberVoices: Bool
    var calibrated: Bool
    var people: [Person]
}
