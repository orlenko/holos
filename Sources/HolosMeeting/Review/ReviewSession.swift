import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// Where "Assign to…" (and a turn's speaker pop-up) sends turns.
public enum ReviewAssignTarget: Sendable, Equatable {
    /// A speaker of this meeting.
    case speaker(String)
    /// The unknown speaker.
    case unknown
    /// A new speaker of this meeting, optionally named.
    case newSpeaker(name: String?)
    /// A known person: the meeting's speaker linked to them, or a new speaker linked to them.
    case person(profileID: String)
}

/// One word of a turn, for choosing where to split it.
public struct ReviewWord: Sendable, Equatable {
    public let ref: WordRef
    public let text: String
    /// Session time.
    public let start: Double

    public init(ref: WordRef, text: String, start: Double) {
        self.ref = ref; self.text = text; self.start = start
    }
}

/// The review window's model (docs/meeting-design.md §5.10): one meeting's speaker labels, edited through
/// `SpeakerEditor` and `VoiceProfileService`, with the window's undo, playback clips, previews, and search. No AppKit.
///
/// Edits are optimistic and serial. Each change is shown at once in `projection` (`SpeakerProjection.applying` on
/// top of the saved labels), queued, and saved in order off the main actor; the saved result then replaces the
/// optimistic one. Every save is a compare-and-append against the labels the change was made on: a change made while
/// earlier ones were still saving is saved on their result only if nothing else changed the labels meanwhile, and a
/// refused change reloads the labels from disk and throws. Turns a pending split created are renamed to their saved
/// IDs (`resolvedTurnID`).
///
/// Exports are regenerated `exportDelay` after the last change (and at `close`), not on every edit. Voice samples
/// learned from this meeting are brought in step after every change that affects them. Nothing here logs transcript
/// text, names, or voice data.
@MainActor public final class ReviewSession {
    private nonisolated static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "review")
    /// `SpeakerEdit.source` of the window's edits.
    nonisolated static let source = "app"
    /// Said when a change was refused because the labels changed outside this window (the window then shows them).
    public nonisolated static let changedElsewhere = "The speaker labels changed outside this window, so that change "
        + "was not saved. The window now shows the current labels."

    public let session: URL
    public let profiles: SpeakerProfileStore?
    private let maintenance: MaintenanceLauncher?
    private let extractor: (any VoiceSampleExtractor)?
    private let exportDelay: Duration

    /// The saved labels, as last loaded from disk.
    public private(set) var snapshot: SpeakerSessionSnapshot
    /// What the window shows: updated at once by each edit (`SpeakerProjection.applying`), then replaced by the
    /// editor's result.
    public private(set) var projection: SpeakerProjection
    public var onChange: (() -> Void)?
    /// Called with true when a relabel (Find More Speakers, Label Speakers on My Microphone, Label Again) starts and
    /// false when it ends, so the app can show it in Meetings.
    public var onRelabelChange: ((Bool) -> Void)?
    /// "Learn voices of people I name in this meeting"; defaults to the global "Remember voices" setting.
    public var learnVoices: Bool
    /// The global "Remember voices" setting when the window opened (or last reloaded people).
    public private(set) var rememberVoices: Bool
    /// What the window is doing right now ("Saving…"), nil when idle.
    public private(set) var activity: String?
    /// When this window last saved a change.
    public private(set) var lastSavedAt: Date?
    /// Hand-edited export files moved aside since the window opened (names in `exports/`).
    public private(set) var movedAsideExports: [String] = []
    /// A change was saved and `exports/` has not been rewritten since.
    public private(set) var exportsPending = false
    /// Why the last export regeneration failed, until one succeeds.
    public private(set) var exportProblem: String?

    /// Test seam: awaited off the main actor before each change is written, so a test can hold a save back.
    var beforeEdit: (@Sendable () async -> Void)?

    private var savedProjection: SpeakerProjection
    private var people: [SpeakerProfile]
    private var profileNames: [String: String]
    private var segments: [String: TranscriptSegment]
    private var textCache: [String: (spans: [WordSpan], text: String)] = [:]
    private var knownEditedExports: Set<String>

    private var queue: [Operation] = []
    private var draining = false
    /// Saved batches this window can undo, oldest first; one entry per user change (a change may save two batches).
    private var undoStack: [[String]] = []
    /// Bumped whenever `snapshot` is replaced.
    private var savedVersion = 0
    /// The last `savedVersion` that brought changes not made by this window's queue (a reload, a relabel, another
    /// process's edits). Changes made on a view older than it are refused.
    private var externalVersion = 0
    /// Optimistic split edit ID → the ID the editor gave it, so a turn created by a pending split keeps working.
    private var editIDMap: [String: String] = [:]
    /// Applied optimistic edit IDs → the queued change that made them, for counting changes.
    private var optimisticOwner: [String: ObjectIdentifier] = [:]
    private var exportTimer: Task<Void, Never>?
    private var closed = false

    // MARK: - Opening

    /// Loads the snapshot off the main actor. `exportDelay` debounces export regeneration.
    ///
    /// `extractor` learns voices (`VoiceSampleExtractor`); nil uses the bundled `holos` tool
    /// (`SubprocessVoiceSampleExtractor`) when `maintenance` is given, else no voice is learned. Throws
    /// `HolosError.unavailable` when the meeting has no usable speaker labels.
    public init(session: URL, profiles: SpeakerProfileStore?, maintenance: MaintenanceLauncher?,
                exportDelay: Duration = .seconds(2), extractor: (any VoiceSampleExtractor)? = nil) async throws {
        let loaded = try await Self.detached { try Self.load(session: session, profiles: profiles) }
        guard let projection = loaded.snapshot.projection else {
            throw HolosError.unavailable(loaded.snapshot.runProblem
                ?? "This meeting's speakers are not labelled yet. Label its speakers first.")
        }
        self.session = session
        self.profiles = profiles
        self.maintenance = maintenance
        self.extractor = extractor ?? maintenance.map { SubprocessVoiceSampleExtractor(executable: $0.executable) }
        self.exportDelay = exportDelay
        snapshot = loaded.snapshot
        self.projection = projection
        savedProjection = projection
        people = loaded.people
        profileNames = loaded.profileNames
        rememberVoices = loaded.rememberVoices
        learnVoices = loaded.rememberVoices
        segments = Self.segmentIndex(loaded.snapshot.transcript)
        knownEditedExports = loaded.editedExports
        Self.log.info("Session \(loaded.snapshot.manifest.id, privacy: .public): review opened on run \(projection.runID, privacy: .public) (\(projection.speakers.count, privacy: .public) speakers, \(projection.turns.count, privacy: .public) turns)")
    }

    // MARK: - Reading

    public var sessionName: String { snapshot.manifest.name }

    /// Seconds from the session start to the end of the last saved chunk.
    public var durationSeconds: Double {
        max(snapshot.manifest.chunks.map(\.end).max() ?? 0, projection.turns.map(\.end).max() ?? 0)
    }

    /// Edits can be made: the labels are usable, no relabel is queued or running, and the window is open.
    public var isEditable: Bool { !closed && snapshot.projection != nil && !isRelabelling }

    /// Find More Speakers, Label Speakers on My Microphone, or Label Again is queued or running.
    public var isRelabelling: Bool {
        queue.contains { if case .relabel = $0.kind { true } else { false } }
    }

    /// Something is queued or saving.
    public var isWorking: Bool { !queue.isEmpty }

    public var canUndo: Bool { !undoStack.isEmpty || queue.contains { $0.isUndoable && !$0.undone } }

    /// Changes to this meeting's labels in effect (a batch counts once; linking a person is one change).
    public var changeCount: Int {
        var batchOf: [String: String] = [:]
        for edit in snapshot.journal.edits where edit.baseRunID == savedProjection.runID {
            batchOf[edit.id] = edit.batchID ?? edit.id
        }
        var keys = Set<String>()
        for id in projection.appliedEditIDs {
            if let batch = batchOf[id] {
                keys.insert("b:" + batch)
            } else if let owner = optimisticOwner[id] {
                keys.insert("o:\(owner.hashValue)")
            } else {
                keys.insert("e:" + id)
            }
        }
        return keys.count
    }

    /// Journal lines of this run that could not be applied.
    public var staleEditCount: Int { projection.staleEdits.count }

    /// Known people, most recently used first (the name combo box and the turn pop-up).
    public func knownPeople() -> [SpeakerProfile] { people }

    public func speaker(_ speakerID: String) -> ProjectedSpeaker? {
        projection.speakers.first { $0.id == speakerID }
    }

    /// The turn a window-held ID now names: a turn made by a split that was pending when the ID was taken gets its
    /// saved ID once the split is saved.
    public func resolvedTurnID(_ turnID: String) -> String {
        guard turnID.contains("/") else { return turnID }
        return turnID.split(separator: "/", omittingEmptySubsequences: false)
            .map { editIDMap[String($0)] ?? String($0) }.joined(separator: "/")
    }

    public func turn(_ turnID: String) -> ProjectedTurn? {
        let id = resolvedTurnID(turnID)
        return projection.turns.first { $0.id == id }
    }

    /// The text the window shows for a turn: its words in the transcript the head run was built from.
    ///
    /// Every place the window reads turn text goes through here (rows, search, previews, the split sheet), and turns
    /// keep referring to words by span, so a later per-turn language choice can supply another transcript's text
    /// for a turn here, keyed by turn ID, without changing `ProjectedTurn` or the edit journal.
    public func text(of turn: ProjectedTurn) -> String {
        if let cached = textCache[turn.id], cached.spans == turn.spans { return cached.text }
        let text = Self.text(of: turn.spans, segments: segments, transcript: snapshot.transcript)
        textCache[turn.id] = (turn.spans, text)
        return text
    }

    /// Turns whose text contains `query`, ignoring case (and diacritics), in time order. Every turn for an empty query.
    public func turns(matching query: String) -> [ProjectedTurn] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return projection.turns }
        return projection.turns.filter {
            text(of: $0).range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The next uncertain turn after `turnID` in time order, wrapping around to the first; the first uncertain turn
    /// when `turnID` is nil or not shown. Nil when no turn is uncertain.
    public func nextUncertain(after turnID: String?) -> ProjectedTurn? {
        let turns = projection.turns
        guard !turns.isEmpty else { return nil }
        let current = turnID.map(resolvedTurnID).flatMap { id in turns.firstIndex { $0.id == id } }
        let start = current.map { $0 + 1 } ?? 0
        for offset in 0..<turns.count {
            let turn = turns[(start + offset) % turns.count]
            if turn.uncertain { return turn }
        }
        return nil
    }

    /// Up to three clips from the speaker's longest non-overlapped turns:
    /// [start + 0.25, min(end, start + 4.25)], or the whole turn when shorter.
    ///
    /// "Shorter" is a turn of at most 4 s. Clips are ordered longest turn first (ties by time).
    public func sampleClips(for speakerID: String) -> [ClosedRange<Double>] {
        longest(of: speakerID) { !$0.overlap && $0.start.isFinite && $0.end.isFinite && $0.end > $0.start }
            .prefix(3).map { turn in
            guard turn.end - turn.start > Self.clipSeconds else { return turn.start...turn.end }
            return (turn.start + Self.clipLead)...min(turn.end, turn.start + Self.clipLead + Self.clipSeconds)
        }
    }

    /// The first 60 characters of the speaker's two longest turns.
    ///
    /// Longest first; runs of whitespace become one space; turns without text are skipped.
    public func previews(for speakerID: String) -> [String] {
        var previews: [String] = []
        for turn in longest(of: speakerID, where: { _ in true }) {
            let text = Self.oneLine(text(of: turn))
            guard !text.isEmpty else { continue }
            previews.append(String(text.prefix(Self.previewCharacters)))
            if previews.count == 2 { break }
        }
        return previews
    }

    /// The words of a turn, in order, for choosing where to split it (a split goes before a word other than the
    /// first).
    public func words(of turnID: String) -> [ReviewWord] {
        guard let turn = turn(turnID) else { return [] }
        var words: [ReviewWord] = []
        for span in turn.spans {
            guard let segment = segments[span.segmentID] else { continue }
            let effective = WordTiming.effectiveWords(of: segment)
            guard span.first >= 0, span.first < span.end, span.end <= effective.count else { continue }
            for index in span.first..<span.end {
                let word = effective[index]
                words.append(ReviewWord(ref: WordRef(segmentID: span.segmentID, word: index), text: word.text,
                                        start: word.start))
            }
        }
        return words
    }

    /// The person a speaker is named after automatically ("Jim (auto)"), for "Not Jim". Nil when the speaker's name
    /// is not automatic.
    public func automaticProfileID(for speakerID: String) -> String? {
        guard let speaker = speaker(speakerID), speaker.isAutomatic else { return nil }
        return snapshot.recognition?.matches.first {
            $0.speakerID == speakerID && $0.tier == .likely && profileNames[$0.profileID] != nil
                && !speaker.rejectedProfileIDs.contains($0.profileID)
        }?.profileID
    }

    /// Find More Speakers is possible: exactly one track was split into speakers (a minimum speaker count cannot be
    /// asked of two tracks at once).
    public var canFindMoreSpeakers: Bool { diarizedTrack != nil && maintenance != nil }

    /// The speaker count Find More Speakers asks for at least: one more than the diarizer found on its track.
    public var findMoreSpeakersMinimum: Int? { diarizedTrack.map { $0.clusters.count + 1 } }

    /// Label Speakers on My Microphone is possible: a call whose microphone was taken as one speaker ("Me").
    public var canLabelMicrophoneSpeakers: Bool {
        maintenance != nil && snapshot.meeting.mode == .call
            && snapshot.run?.tracks.contains { $0.track == "mic" && Self.isChannel($0.policy) } == true
    }

    // MARK: - Editing

    /// Edits run in order on a serial queue off the main actor (SpeakerEditor, regenerateExports: false).
    /// A refused edit reloads the snapshot and throws. Pushes undo; schedules exports.
    ///
    /// Names are saved as `SpeakerEditor.cleanName` gives them. A batch that changes nothing returns at once and
    /// saves nothing; one that is not valid on the shown labels throws `invalidInput` and saves nothing.
    public func apply(_ actions: [SpeakerEditAction]) async throws {
        try requireEditable()
        let resolved = actions.map { Self.cleaned(resolve($0)) }
        guard !resolved.isEmpty else { return }
        try validate(resolved)
        if SpeakerEditor.changesNothing(resolved, on: projection) { return }
        try await enqueue(.edit(resolved), optimistic: resolved)
    }

    /// This window's newest change: a queued one is dropped (or reverted once saved), else the newest saved batch is
    /// reverted. Undo never reaches changes made outside the window. Throws `invalidInput` when there is none.
    public func undo() async throws {
        try requireEditable()
        if let op = queue.last(where: { $0.isUndoable && !$0.undone }) {
            op.undone = true
            if !op.started {
                queue.removeAll { $0 === op }
                op.finish(.success(()))
                recomputeProjection()
                notify()
                Self.log.info("Session \(self.sessionID, privacy: .public): dropped an unsaved change (undo)")
                return
            }
            try await enqueue(.undo(.operation(op)), optimistic: [])
            return
        }
        guard let batches = undoStack.popLast() else {
            throw HolosError.invalidInput("There is no change in this window to undo.")
        }
        try await enqueue(.undo(.batches(batches)), optimistic: [])
    }

    /// Links the speaker to a known person or a new one; the person's name becomes the speaker's. Learns the voice
    /// when `learnVoices` is on (and Remember voices).
    public func link(speakerID: String, to target: ProfileTarget) async throws {
        try await link(speakerID: speakerID, to: target, byName: false)
    }

    /// `byName`: the name field asked for "the person called this" (`setName`), so a `.new` target that a person of
    /// that name exists for by the time the change is saved (one created by an earlier change still saving) links
    /// that person instead of creating a second one.
    private func link(speakerID: String, to target: ProfileTarget, byName: Bool) async throws {
        try requireEditable()
        try requirePeople()
        guard projection.speakers.contains(where: { $0.id == speakerID }) else { throw Self.noSpeaker(speakerID) }
        var optimistic: [SpeakerEditAction] = []
        switch target {
        case .existing(let profileID):
            guard let person = people.first(where: { $0.id == profileID }) else {
                throw HolosError.invalidInput("That person is not known to Holos any more; reopen the window.")
            }
            optimistic = [.linkProfile(speakerID: speakerID, profileID: profileID),
                          .rename(speakerID: speakerID, name: person.displayName)]
        case .new(let name):
            guard let clean = SpeakerEditor.cleanName(name) else {
                throw HolosError.invalidInput("A new person needs a name.")
            }
            optimistic = [.rename(speakerID: speakerID, name: clean)]
        }
        try await enqueue(.link(speakerID: speakerID, target: target, learnVoice: learnVoices, byName: byName),
                          optimistic: optimistic)
    }

    /// The name field's Return: an empty name clears the speaker's name (and unlinks the person it is linked to, whose
    /// name it would otherwise keep showing); a known person's name (ignoring case) links the speaker to them (the
    /// most recently used one when two share it); any other name creates that person and links the speaker. A name
    /// whose person is still being created by an earlier change links that person once it is saved. Without a people
    /// store the name is only set on the speaker.
    public func setName(_ text: String, speakerID: String) async throws {
        try requireEditable()
        guard let speaker = speaker(speakerID) else { throw Self.noSpeaker(speakerID) }
        guard let name = SpeakerEditor.cleanName(text) else {
            var actions: [SpeakerEditAction] = [.rename(speakerID: speakerID, name: nil)]
            if let profileID = speaker.profileID {
                actions.append(.rejectProfile(speakerID: speakerID, profileID: profileID))
            }
            try await apply(actions)
            return
        }
        guard profiles != nil else {
            try await apply([.rename(speakerID: speakerID, name: name)])
            return
        }
        if let person = person(named: name) {
            if speaker.profileID == person.id, speaker.name == person.displayName { return }
            try await link(speakerID: speakerID, to: .existing(profileID: person.id), byName: true)
        } else {
            // Return pressed again while this speaker's link to that new name is still waiting or saving.
            if speaker.name == name, pendingLinkByName(speakerID: speakerID, name: name) { return }
            try await link(speakerID: speakerID, to: .new(name: name), byName: true)
        }
    }

    /// The known person called `name` (cleaned, ignoring case), the most recently used one when two share it.
    private func person(named name: String) -> SpeakerProfile? {
        guard let clean = SpeakerEditor.cleanName(name) else { return nil }
        return people.first { $0.displayName.caseInsensitiveCompare(clean) == .orderedSame }
    }

    /// A name-field link of `speakerID` to a new person called `name` is queued or saving and not undone.
    private func pendingLinkByName(speakerID: String, name: String) -> Bool {
        queue.contains { op in
            guard !op.undone, case .link(let id, .new(let pending), _, true) = op.kind else { return false }
            return id == speakerID && pending.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Moves turns to a speaker, the unknown speaker, a new speaker, or a person, as one change.
    public func assign(_ turnIDs: [String], to target: ReviewAssignTarget) async throws {
        try requireEditable()
        var seen = Set<String>()
        let ids = turnIDs.map(resolvedTurnID).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        switch target {
        case .speaker(let speakerID):
            try await apply([.reassignTurns(turnIDs: ids, to: speakerID)])
        case .unknown:
            try await apply([.reassignTurns(turnIDs: ids, to: nil)])
        case .newSpeaker(let name):
            try await apply([.newSpeaker(speakerID: Self.newSpeakerID(), name: name, turnIDs: ids)])
        case .person(let profileID):
            if let speaker = projection.speakers.first(where: { $0.profileID == profileID }) {
                try await apply([.reassignTurns(turnIDs: ids, to: speaker.id)])
                return
            }
            try requirePeople()
            guard let person = people.first(where: { $0.id == profileID }) else {
                throw HolosError.invalidInput("That person is not known to Holos any more; reopen the window.")
            }
            let speakerID = Self.newSpeakerID()
            let create = SpeakerEditAction.newSpeaker(speakerID: speakerID, name: person.displayName, turnIDs: ids)
            try validate([create])
            try await enqueue(.assignPerson(create: create, speakerID: speakerID, profileID: profileID,
                                            learnVoice: learnVoices),
                              optimistic: [create, .linkProfile(speakerID: speakerID, profileID: profileID)])
        }
    }

    /// Splits a turn before `word` (a word of the turn other than its first).
    public func split(turnID: String, at word: WordRef) async throws {
        try await apply([.splitTurn(turnID: resolvedTurnID(turnID), at: word)])
    }

    /// Moves every turn of `speakerID` to `target`; `speakerID` disappears. `target` keeps its name.
    public func merge(_ speakerID: String, into target: String) async throws {
        try await apply([.merge(from: speakerID, into: target)])
    }

    /// Links every suggestion ("Maybe Jim") to its person as one change (one undo), learning voices when
    /// `learnVoices` is on.
    public func confirmAllSuggestions() async throws {
        try requireEditable()
        try requirePeople()
        let known = Set(people.map(\.id))
        let optimistic = projection.speakers.flatMap { speaker -> [SpeakerEditAction] in
            guard let suggestion = speaker.suggestion, known.contains(suggestion.profileID) else { return [] }
            let name = people.first { $0.id == suggestion.profileID }?.displayName ?? suggestion.profileName
            return [.linkProfile(speakerID: speaker.id, profileID: suggestion.profileID),
                    .rename(speakerID: speaker.id, name: name)]
        }
        guard !optimistic.isEmpty else { throw HolosError.invalidInput("There are no suggested names to confirm.") }
        try await enqueue(.confirmAll(learnVoices: learnVoices), optimistic: optimistic)
    }

    /// "This is me": links the speaker to you (the one `isSelf` person, created on first use). Passes `learnVoices`
    /// to `VoiceProfileService.markSelf`.
    public func markSelf(speakerID: String) async throws {
        try requireEditable()
        try requirePeople()
        guard projection.speakers.contains(where: { $0.id == speakerID }) else { throw Self.noSpeaker(speakerID) }
        let optimistic: [SpeakerEditAction]
        if let me = people.first(where: \.isSelf) {
            optimistic = [.linkProfile(speakerID: speakerID, profileID: me.id),
                          .rename(speakerID: speakerID, name: me.displayName)]
        } else {
            optimistic = [.rename(speakerID: speakerID, name: VoiceProfileService.selfName)]
        }
        try await enqueue(.markSelf(speakerID: speakerID, learnVoice: learnVoices), optimistic: optimistic)
    }

    /// "Not Maria" for the speaker's suggestion, or "Not Jim" for its automatic name, in this meeting only.
    public func rejectSuggestion(speakerID: String) async throws {
        guard let speaker = speaker(speakerID) else { throw Self.noSpeaker(speakerID) }
        guard let profileID = speaker.suggestion?.profileID ?? automaticProfileID(for: speakerID) else {
            throw HolosError.invalidInput("This speaker has no suggested name to reject.")
        }
        try await apply([.rejectProfile(speakerID: speakerID, profileID: profileID)])
    }

    /// `holos session diarize --force --min-speakers <current + 1>`; names carry over (§4.9).
    ///
    /// "Current" is the number of speakers the diarizer found on the one track it split. Turn-level changes are not
    /// carried; the window's undo history ends here. Throws when the relabel fails (`unavailable`) or finished with
    /// a warning (`incomplete`, with its message); the labels are reloaded either way.
    public func findMoreSpeakers() async throws {
        try requireEditable()
        guard let minimum = findMoreSpeakersMinimum, maintenance != nil else {
            throw HolosError.invalidInput("Find More Speakers works when one track of the meeting was split into "
                                          + "speakers.")
        }
        try await relabel(Self.relabelArguments(session: session, force: true, minimumSpeakers: minimum,
                                                othersInRoom: othersInRoomFlag))
    }

    /// `holos session diarize --force --others-in-room` (call recordings).
    public func labelMicrophoneSpeakers() async throws {
        try requireEditable()
        guard canLabelMicrophoneSpeakers else {
            throw HolosError.invalidInput("Only a call whose microphone was labelled as you alone can be labelled "
                                          + "again with the people in the room.")
        }
        try await relabel(Self.relabelArguments(session: session, force: true, minimumSpeakers: nil,
                                                othersInRoom: true))
    }

    /// Labels the speakers again after the transcript changed (`holos session diarize`); names carry over.
    public func labelAgain() async throws {
        try requireEditable()
        guard maintenance != nil else { throw HolosError.unavailable("Speakers cannot be labelled from here.") }
        try await relabel(Self.relabelArguments(session: session, force: false, minimumSpeakers: nil,
                                                othersInRoom: othersInRoomFlag))
    }

    /// One export format of the labels as saved once every queued change is saved (Save As…, Copy as Markdown).
    /// Written nowhere; `exports/` is brought up to date on the way when it is behind.
    public func render(_ format: ExportFormat) async throws -> Data {
        guard !closed else { throw Self.closedError }
        try? await enqueue(.exports, optimistic: [])
        let session = self.session
        let names = profileNames
        return try await Self.detached { try SessionExports.render(format, session: session, profileNames: names) }
    }

    /// Rereads the labels from disk (after a change made elsewhere, such as Delete Audio or a relabel from
    /// Meetings). Changes still queued in this window that were made on the older labels are refused.
    public func reload() async {
        guard !closed else { return }
        try? await enqueue(.reload, optimistic: [])
    }

    /// Regenerates exports now if an edit is pending. Call when the window closes.
    ///
    /// Waits for queued changes to be saved first; later edits are refused.
    public func close() async {
        guard !closed else { return }
        closed = true
        exportTimer?.cancel()
        exportTimer = nil
        do {
            try await enqueue(.exports, optimistic: [])
        } catch {
            Self.log.error("Session \(self.sessionID, privacy: .public): exports not rewritten at close (\(ProcessSpawner.logCategory(error), privacy: .public))")
        }
        Self.log.info("Session \(self.sessionID, privacy: .public): review closed")
    }

    // MARK: - Relabel arguments

    /// `session diarize <path> [--force] [--min-speakers N] [--others-in-room | --no-others-in-room] --json`.
    nonisolated static func relabelArguments(session: URL, force: Bool, minimumSpeakers: Int?,
                                             othersInRoom: Bool?) -> [String] {
        var arguments = ["session", "diarize", session.path]
        if force { arguments.append("--force") }
        if let minimumSpeakers { arguments += ["--min-speakers", String(minimumSpeakers)] }
        if let othersInRoom { arguments.append(othersInRoom ? "--others-in-room" : "--no-others-in-room") }
        arguments.append("--json")
        return arguments
    }

    // MARK: - Queue

    /// One queued change or task.
    @MainActor private final class Operation {
        enum UndoTarget {
            /// Saved batches of this window, newest last.
            case batches([String])
            /// Whatever an earlier queued change saves.
            case operation(Operation)
        }

        enum Kind {
            case edit([SpeakerEditAction])
            /// `byName`: from the name field; a `.new` target is linked to a person of that name existing at save time.
            case link(speakerID: String, target: ProfileTarget, learnVoice: Bool, byName: Bool)
            case assignPerson(create: SpeakerEditAction, speakerID: String, profileID: String, learnVoice: Bool)
            case confirmAll(learnVoices: Bool)
            case markSelf(speakerID: String, learnVoice: Bool)
            case undo(UndoTarget)
            case relabel([String])
            case reload
            case exports
        }

        let kind: Kind
        /// `savedVersion` when the change was made.
        let basis: Int
        /// Actions shown at once (turn IDs as the window had them) and their optimistic edit IDs.
        let optimistic: [SpeakerEditAction]
        let optimisticIDs: [String]
        var started = false
        /// Undone before it was saved: not shown, and an undo reverts what it saves.
        var undone = false
        /// Labels were adopted while it ran (its own result, or a reload after a refusal): the saved labels now
        /// show whatever it did, so its optimistic actions are no longer shown.
        var superseded = false
        var finished = false
        /// Batches it saved.
        var batches: [String] = []
        var continuation: CheckedContinuation<Void, any Error>?

        init(kind: Kind, basis: Int, optimistic: [SpeakerEditAction]) {
            self.kind = kind
            self.basis = basis
            self.optimistic = optimistic
            optimisticIDs = optimistic.map { _ in UUID().uuidString }
        }

        /// A change of the labels the window's undo can take back.
        var isUndoable: Bool {
            switch kind {
            case .edit, .link, .assignPerson, .confirmAll, .markSelf: true
            case .undo, .relabel, .reload, .exports: false
            }
        }

        func finish(_ result: Result<Void, any Error>) {
            finished = true
            continuation?.resume(with: result)
            continuation = nil
        }
    }

    private func enqueue(_ kind: Operation.Kind, optimistic: [SpeakerEditAction]) async throws {
        let op = Operation(kind: kind, basis: savedVersion, optimistic: optimistic)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            op.continuation = continuation
            queue.append(op)
            recomputeProjection()
            updateActivity()
            notify()
            startDraining()
        }
    }

    private func startDraining() {
        guard !draining else { return }
        draining = true
        Task { await self.drain() }
    }

    private func drain() async {
        while let op = queue.first {
            op.started = true
            activity = activityText(op)
            notify()
            let result: Result<Void, any Error>
            do {
                try await run(op)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            queue.removeAll { $0 === op }
            if op.isUndoable, !op.undone, !op.batches.isEmpty { undoStack.append(op.batches) }
            op.finish(result)
            recomputeProjection()
            updateActivity()
            notify()
        }
        draining = false
    }

    private func run(_ op: Operation) async throws {
        switch op.kind {
        case .edit(let actions):
            try requireBasis(op)
            let sent = actions.map(resolve)
            try await saveEdit(sent, op: op) { batch in batch.map(\.action) == sent }
        case .link(let speakerID, let asked, let learnVoice, let byName):
            try requireBasis(op)
            var resolved = asked
            if byName, case .new(let name) = asked {
                // An earlier change still saving when this one was made may have created the person since.
                await reloadPeople()
                if let person = person(named: name) { resolved = .existing(profileID: person.id) }
            }
            let target = resolved
            let view = savedProjection
            try await savePeopleChange(op, matching: Self.linkBatch(speakerID)) { session, store, extractor in
                try await VoiceProfileService.link(session: session, speakerID: speakerID, to: target, view: view,
                                                   learnVoice: learnVoice, extractor: extractor, store: store)
            }
        case .assignPerson(let create, let speakerID, let profileID, let learnVoice):
            try requireBasis(op)
            let sent = resolve(create)
            try await saveEdit([sent], op: op) { batch in batch.map(\.action) == [sent] }
            let view = savedProjection
            try await savePeopleChange(op, matching: Self.linkBatch(speakerID)) { session, store, extractor in
                try await VoiceProfileService.link(session: session, speakerID: speakerID,
                                                   to: .existing(profileID: profileID), view: view,
                                                   learnVoice: learnVoice, extractor: extractor, store: store)
            }
        case .confirmAll(let learnVoices):
            try requireBasis(op)
            let view = savedProjection
            try await savePeopleChange(op, matching: Self.confirmBatch) { session, store, extractor in
                try await VoiceProfileService.confirmAll(session: session, view: view, learnVoices: learnVoices,
                                                         extractor: extractor, store: store)
            }
        case .markSelf(let speakerID, let learnVoice):
            try requireBasis(op)
            let view = savedProjection
            try await savePeopleChange(op, matching: Self.linkBatch(speakerID)) { session, store, extractor in
                try await VoiceProfileService.markSelf(session: session, speakerID: speakerID, view: view,
                                                       learnVoice: learnVoice, extractor: extractor, store: store)
            }
        case .undo(let target):
            let batches: [String]
            switch target {
            case .batches(let saved): batches = saved
            case .operation(let earlier): batches = earlier.batches
            }
            for batch in batches.reversed() {
                try await undoBatch(batch, op: op)
            }
        case .relabel(let arguments):
            try await runRelabel(arguments)
        case .reload:
            let fresh = try await loadSnapshot()
            await reloadPeople()
            adopt(fresh, op: nil, matching: nil)
        case .exports:
            try await regenerateExports()
        }
    }

    // MARK: - Saving

    /// Saves `actions` with `SpeakerEditor` on the saved labels, then adopts the result.
    private func saveEdit(_ actions: [SpeakerEditAction], op: Operation,
                          matching: @escaping ([SpeakerEdit]) -> Bool) async throws {
        let view = savedProjection
        let session = self.session
        let names = profileNames
        let store = profiles
        let hook = beforeEdit
        let outcome = await Self.detachedResult { () throws -> SpeakerEditResult in
            if let hook { await hook() }
            return try SpeakerEditor.apply(actions, view: view, session: session, source: Self.source,
                                           regenerateExports: false, profileNames: names, profiles: store)
        }
        switch outcome {
        case .success(let result):
            if adopt(result.snapshot, op: op, matching: matching) { changesSaved(exportsWritten: false) }
            if result.needsSampleRefresh { try await refreshSamples() }
        case .failure(let error):
            try await handleFailure(error, op: op, refreshSamples: true, matching: matching)
        }
    }

    /// Runs a `VoiceProfileService` change (it saves the journal and rewrites the exports itself), then adopts the
    /// labels it returns (loaded with the people store's names, which are the window's) and rereads the people.
    private func savePeopleChange(
        _ op: Operation, matching: @escaping ([SpeakerEdit]) -> Bool,
        _ change: @escaping @Sendable (URL, SpeakerProfileStore, (any VoiceSampleExtractor)?) async throws
            -> SpeakerSessionSnapshot
    ) async throws {
        guard let store = profiles else { throw Self.noPeople }
        let session = self.session
        let extractor = self.extractor
        let hook = beforeEdit
        let outcome = await Self.detachedResult { () throws -> SpeakerSessionSnapshot in
            if let hook { await hook() }
            return try await change(session, store, extractor)
        }
        switch outcome {
        case .success(let returned):
            await reloadPeople()
            // A link that changed nothing saved nothing and rewrote no export.
            if adopt(returned, op: op, matching: matching) { changesSaved(exportsWritten: true) }
        case .failure(let error):
            await reloadPeople()
            try await handleFailure(error, op: op, matching: matching)
        }
    }

    /// A save that threw. `incomplete` means its lines were saved and something after failed (reloading, the
    /// exports, or a voice sample): the labels are reloaded, the lines kept as the window's, and the error is
    /// thrown. Anything else refused the change: the labels are reloaded (queued changes made on the older labels are
    /// then refused too) and the error is thrown, with `changedElsewhere` for a stale view.
    ///
    /// `refreshSamples`: the change was saved by `SpeakerEditor` here (not by `VoiceProfileService`, which brings
    /// samples in step itself), so on `incomplete` this meeting's voice samples are brought in step before the error
    /// is thrown (`needsSampleRefresh` was lost with it).
    private func handleFailure(_ error: any Error, op: Operation?, refreshSamples: Bool = false,
                               matching: @escaping ([SpeakerEdit]) -> Bool) async throws {
        if error is CancellationError { throw error }
        if case .incomplete? = error as? HolosError {
            if let fresh = try? await loadSnapshot() { adopt(fresh, op: op, matching: matching) }
            changesSaved(exportsWritten: false)
            Self.log.error("Session \(self.sessionID, privacy: .public): a change was saved, then failed (\(ProcessSpawner.logCategory(error), privacy: .public))")
            if refreshSamples, let store = profiles {
                let session = self.session
                let extractor = self.extractor
                activity = "Updating a voice sample…"
                notify()
                try await Self.detached { () async throws -> Void in
                    try await VoiceProfileService.refreshSamples(afterSaving: error, session: session,
                                                                 extractor: extractor, store: store)
                }
            }
            throw error
        }
        Self.log.notice("Session \(self.sessionID, privacy: .public): a change was refused (\(ProcessSpawner.logCategory(error), privacy: .public)); reloading")
        if let fresh = try? await loadSnapshot() {
            adopt(fresh, op: nil, matching: nil, external: true)
        }
        if case .unavailable(let message)? = error as? HolosError, message == SpeakerEditor.changedMessage {
            throw HolosError.unavailable(Self.changedElsewhere)
        }
        throw error
    }

    /// Reverts one saved batch of this window: `undoLast` when it is the newest batch, else reverts of its lines in
    /// effect (refused when that would change other edits).
    private func undoBatch(_ batch: String, op: Operation) async throws {
        let view = savedProjection
        let lines = snapshot.journal.edits
            .filter { $0.baseRunID == view.runID && ($0.batchID ?? $0.id) == batch }.map(\.id)
        let applied = Set(view.appliedEditIDs).intersection(lines)
        guard !applied.isEmpty else {
            Self.log.notice("Session \(self.sessionID, privacy: .public): the change to undo is no longer in effect")
            return
        }
        let session = self.session
        let store = profiles
        let names = profileNames
        let hook = beforeEdit
        let ordered = lines.filter(applied.contains)
        let newest = view.lastUndoableBatchID == batch
        let outcome = await Self.detachedResult { () throws -> SpeakerEditResult in
            if let hook { await hook() }
            if newest {
                return try SpeakerEditor.undoLast(view: view, session: session, source: Self.source,
                                                  regenerateExports: false, profiles: store)
            }
            return try SpeakerEditor.apply(ordered.map { .revert(editID: $0) }, view: view, session: session,
                                           source: Self.source, regenerateExports: false, profileNames: names,
                                           profiles: store)
        }
        let matching: ([SpeakerEdit]) -> Bool = { lines in
            let targets = Set(lines.compactMap { line -> String? in
                if case .revert(let editID) = line.action { return editID }
                return nil
            })
            return targets.count == lines.count && applied.isSubset(of: targets)
        }
        switch outcome {
        case .success(let result):
            // `undoLast` loads its result without people's names; the window's labels need them.
            let fresh = newest ? ((try? await loadSnapshot()) ?? result.snapshot) : result.snapshot
            if adopt(fresh, op: nil, matching: matching) { changesSaved(exportsWritten: false) }
            if result.needsSampleRefresh { try await refreshSamples() }
        case .failure(let error):
            try await handleFailure(error, op: nil, refreshSamples: true, matching: matching)
        }
    }

    /// Brings this meeting's voice samples in step after a saved change.
    private func refreshSamples() async throws {
        guard let store = profiles else { return }
        let session = self.session
        let extractor = self.extractor
        activity = "Updating a voice sample…"
        notify()
        do {
            try await Self.detached {
                try await VoiceProfileService.refreshSamples(session: session, extractor: extractor, store: store)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.log.error("Session \(self.sessionID, privacy: .public): voice samples not brought in step (\(ProcessSpawner.logCategory(error), privacy: .public))")
            throw HolosError.incomplete("The change was saved, but a voice sample learned from this meeting could "
                                        + "not be updated: \(error.localizedDescription)")
        }
    }

    /// Replaces the saved labels with `fresh`. The window's own batch (the newest new batch `matching` accepts) is
    /// recorded on `op`, with the saved IDs of turns its splits made; any other new line, or a new head run, is a
    /// change made elsewhere. Returns whether the window's batch was found.
    @discardableResult
    private func adopt(_ fresh: SpeakerSessionSnapshot, op: Operation?, matching: (([SpeakerEdit]) -> Bool)?,
                       external forced: Bool = false) -> Bool {
        let known = Set(snapshot.journal.edits.map(\.id))
        let added = fresh.journal.edits.filter { !known.contains($0.id) }
        var ours: [SpeakerEdit] = []
        if let matching {
            var groups: [[SpeakerEdit]] = []
            var keys: [String] = []
            for edit in added {
                let key = edit.batchID ?? edit.id
                if let index = keys.firstIndex(of: key) {
                    groups[index].append(edit)
                } else {
                    keys.append(key)
                    groups.append([edit])
                }
            }
            // The window writes with source "app"; `VoiceProfileService` names its own ("app" inside Holos.app).
            let sources: Set<String> = [Self.source, VoiceProfileService.editSource]
            if let batch = groups.last(where: { $0.allSatisfy { sources.contains($0.source) } && matching($0) }) {
                ours = batch
                if let op, let first = batch.first {
                    op.batches.append(first.batchID ?? first.id)
                    recordSplits(of: op, lines: batch)
                }
            }
        }
        if let running = queue.first, running.started { running.superseded = true }
        let headChanged = fresh.run?.id != snapshot.run?.id
        let external = forced || headChanged || added.count > ours.count
        let transcriptChanged = fresh.transcript.id != snapshot.transcript.id
        snapshot = fresh
        if let projection = fresh.projection { savedProjection = projection }
        savedVersion += 1
        if transcriptChanged {
            segments = Self.segmentIndex(fresh.transcript)
            textCache.removeAll()
        }
        if headChanged {
            undoStack.removeAll()
            editIDMap.removeAll()
            textCache.removeAll()
        }
        noteMovedAside(Self.editedExports(session: session))
        if external {
            externalVersion = savedVersion
            refuseStaleQueuedChanges()
            Self.log.info("Session \(self.sessionID, privacy: .public): labels changed elsewhere (\(added.count - ours.count, privacy: .public) other lines, head changed: \(headChanged, privacy: .public))")
        }
        recomputeProjection()
        notify()
        return !ours.isEmpty
    }

    /// Queued changes not started yet and made on labels older than the last change from elsewhere: refused.
    private func refuseStaleQueuedChanges() {
        let stale = queue.filter { !$0.started && $0.isUndoable && $0.basis < externalVersion }
        guard !stale.isEmpty else { return }
        queue.removeAll { op in stale.contains { $0 === op } }
        for op in stale { op.finish(.failure(HolosError.unavailable(Self.changedElsewhere))) }
    }

    /// Records the saved IDs of the turns a change's splits created (its lines are its actions, in order).
    private func recordSplits(of op: Operation, lines: [SpeakerEdit]) {
        guard case .edit = op.kind, lines.count == op.optimistic.count else { return }
        for (index, action) in op.optimistic.enumerated() {
            guard case .splitTurn = action, case .splitTurn = lines[index].action else { continue }
            editIDMap[op.optimisticIDs[index]] = lines[index].id
        }
    }

    private func requireBasis(_ op: Operation) throws {
        guard op.basis >= externalVersion else { throw HolosError.unavailable(Self.changedElsewhere) }
    }

    // MARK: - Relabel

    private func relabel(_ arguments: [String]) async throws {
        try await enqueue(.relabel(arguments), optimistic: [])
    }

    private func runRelabel(_ arguments: [String]) async throws {
        guard let maintenance else { throw HolosError.unavailable("Speakers cannot be labelled from here.") }
        onRelabelChange?(true)
        defer { onRelabelChange?(false) }
        let folder = FileManager.default.temporaryDirectory
        let output = folder.appendingPathComponent("holos-command-\(UUID().uuidString).out", isDirectory: false)
        let errors = folder.appendingPathComponent("holos-command-\(UUID().uuidString).err", isDirectory: false)
        defer {
            ProcessSpawner.removeRegularFile(output)
            ProcessSpawner.removeRegularFile(errors)
        }
        Self.log.notice("Session \(self.sessionID, privacy: .public): relabelling from the review window")
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            do {
                try maintenance.run(arguments, standardOutput: output, standardError: errors) { code in
                    continuation.resume(returning: code)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let message = Self.commandMessage(output: output, errors: errors)
        Self.log.notice("Session \(self.sessionID, privacy: .public): relabel ended with \(code, privacy: .public)")
        if let fresh = try? await loadSnapshot() {
            adopt(fresh, op: nil, matching: nil, external: true)
        }
        // 0 and 3 rewrote the exports from the labels now saved; any other code wrote none, so a change of this
        // window still waiting for its exports keeps waiting (they follow `exportDelay` later, or at `close`).
        if code == 0 || code == 3 {
            exportsPending = false
            exportProblem = nil
            exportTimer?.cancel()
            exportTimer = nil
        } else if exportsPending {
            scheduleExports()
        }
        switch code {
        case 0: return
        case 3: throw HolosError.incomplete(message ?? "The speakers were not labelled again.")
        default: throw HolosError.unavailable(message ?? "Holos could not label the speakers again (code \(code)).")
        }
    }

    /// `message` or `summary` of the command's JSON output, else its last stderr line.
    private nonisolated static func commandMessage(output: URL, errors: URL) -> String? {
        if let data = try? AtomicFile.readIfPresent(output, maxBytes: 4 << 20),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for key in ["message", "summary"] {
                if let text = object[key] as? String, !text.isEmpty { return text }
            }
        }
        return ProcessSpawner.lastLine(of: errors)
    }

    // MARK: - Exports

    /// A change was saved. `exportsWritten`: its writer rewrote the exports from the saved labels (a
    /// `VoiceProfileService` change); otherwise (`regenerateExports: false`) they follow `exportDelay` later.
    private func changesSaved(exportsWritten: Bool) {
        lastSavedAt = Date()
        if exportsWritten {
            exportsPending = false
            exportProblem = nil
            exportTimer?.cancel()
            exportTimer = nil
        } else {
            scheduleExports()
        }
    }

    private func scheduleExports() {
        exportsPending = true
        exportTimer?.cancel()
        guard !closed else { return }
        let delay = exportDelay
        exportTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.exportTimer = nil
            try? await self.enqueue(.exports, optimistic: [])
        }
    }

    private func regenerateExports() async throws {
        guard exportsPending else { return }
        activity = "Updating the transcript files…"
        notify()
        let session = self.session
        let names = profileNames
        do {
            let result = try await Self.detached { try SessionExports.regenerate(session: session, profileNames: names) }
            exportsPending = false
            exportProblem = nil
            noteMovedAside(Set(result.movedAside.map(\.lastPathComponent)))
        } catch {
            exportProblem = "The transcript files could not be updated: \(error.localizedDescription)"
            Self.log.error("Session \(self.sessionID, privacy: .public): exports not rewritten (\(ProcessSpawner.logCategory(error), privacy: .public))")
            throw error
        }
    }

    private func noteMovedAside(_ names: Set<String>) {
        let new = names.subtracting(knownEditedExports).sorted()
        guard !new.isEmpty else { return }
        knownEditedExports.formUnion(new)
        movedAsideExports += new
    }

    // MARK: - Projection

    /// The saved labels with every queued change shown.
    private func recomputeProjection() {
        var display = savedProjection
        var owners: [String: ObjectIdentifier] = [:]
        for op in queue {
            let owner = ObjectIdentifier(op)
            for (action, id) in displayActions(op) {
                display = display.applying(action, editID: id)
                owners[id] = owner
            }
        }
        projection = display
        optimisticOwner = owners
    }

    /// What a queued change shows: its actions (with turn IDs of saved splits resolved), nothing once undone, and for
    /// an undo the reverts of the batches it takes back.
    private func displayActions(_ op: Operation) -> [(SpeakerEditAction, String)] {
        guard !op.superseded else { return [] }
        switch op.kind {
        case .undo(.batches(let batches)):
            return reverts(of: batches).map { ($0, UUID().uuidString) }
        case .undo(.operation(let earlier)):
            // Until the earlier change is saved its effect is simply not shown (it is `undone`).
            guard earlier.finished || earlier.superseded else { return [] }
            return reverts(of: earlier.batches).map { ($0, UUID().uuidString) }
        case .relabel, .reload, .exports:
            return []
        case .edit, .link, .assignPerson, .confirmAll, .markSelf:
            guard !op.undone else { return [] }
            return zip(op.optimistic.map(resolve), op.optimisticIDs).map { ($0, $1) }
        }
    }

    /// Reverts of the saved lines in effect of `batches`, newest batch first.
    private func reverts(of batches: [String]) -> [SpeakerEditAction] {
        let applied = Set(savedProjection.appliedEditIDs)
        return batches.reversed().flatMap { batch in
            snapshot.journal.edits
                .filter { ($0.batchID ?? $0.id) == batch && applied.contains($0.id) }
                .map { SpeakerEditAction.revert(editID: $0.id) }
        }
    }

    // MARK: - Helpers

    private var sessionID: String { snapshot.manifest.id }

    /// The one track the run split into speakers, when exactly one was.
    private var diarizedTrack: TrackDiarization? {
        let diarized = snapshot.run?.tracks.filter { $0.policy == .diarized } ?? []
        return diarized.count == 1 ? diarized.first : nil
    }

    /// Keeps a call's choice about the people in the room when relabelling: the microphone was split into speakers
    /// (true) or taken as you (false). Nil for an in-person meeting or when the run does not say.
    private var othersInRoomFlag: Bool? {
        guard snapshot.meeting.mode == .call,
              let microphone = snapshot.run?.tracks.first(where: { $0.track == "mic" }) else { return nil }
        if microphone.policy == .diarized { return true }
        if Self.isChannel(microphone.policy) { return false }
        return nil
    }

    private nonisolated static func isChannel(_ policy: TrackPolicy) -> Bool {
        if case .channel = policy { return true }
        return false
    }

    /// The speaker's turns matching `condition`, longest first (ties by time).
    private func longest(of speakerID: String, where condition: (ProjectedTurn) -> Bool) -> [ProjectedTurn] {
        projection.turns.enumerated()
            .filter { $0.element.speakerID == speakerID && condition($0.element) }
            .sorted { left, right in
                let a = left.element.end - left.element.start
                let b = right.element.end - right.element.start
                return a != b ? a > b : left.offset < right.offset
            }
            .map(\.element)
    }

    private func resolve(_ action: SpeakerEditAction) -> SpeakerEditAction {
        switch action {
        case .reassignTurns(let turnIDs, let to):
            .reassignTurns(turnIDs: turnIDs.map(resolvedTurnID), to: to)
        case .splitTurn(let turnID, let at):
            .splitTurn(turnID: resolvedTurnID(turnID), at: at)
        case .newSpeaker(let speakerID, let name, let turnIDs):
            .newSpeaker(speakerID: speakerID, name: name, turnIDs: turnIDs.map(resolvedTurnID))
        case .excludeFromEnrollment(let turnIDs):
            .excludeFromEnrollment(turnIDs: turnIDs.map(resolvedTurnID))
        case .rename, .linkProfile, .rejectProfile, .merge, .revert:
            action
        }
    }

    /// Names as `SpeakerEditor` saves them, so the shown projection matches the saved one.
    private nonisolated static func cleaned(_ action: SpeakerEditAction) -> SpeakerEditAction {
        switch action {
        case .rename(let speakerID, let name):
            .rename(speakerID: speakerID, name: SpeakerEditor.cleanName(name))
        case .newSpeaker(let speakerID, let name, let turnIDs):
            .newSpeaker(speakerID: speakerID, name: SpeakerEditor.cleanName(name), turnIDs: turnIDs)
        case .linkProfile, .rejectProfile, .merge, .reassignTurns, .splitTurn, .excludeFromEnrollment, .revert:
            action
        }
    }

    /// Throws what the editor would refuse on the shown labels, before anything is queued.
    private func validate(_ actions: [SpeakerEditAction]) throws {
        var state = projection
        for action in actions {
            if case .revert = action {
                throw HolosError.invalidInput("Use Undo to take back a change.")
            }
            let id = UUID().uuidString
            let next = state.applying(action, editID: id)
            if let stale = next.staleEdits.first(where: { $0.editID == id }) {
                throw SpeakerEditor.refusal(action, reason: stale.reason, on: state)
            }
            state = next
        }
    }

    private func requireEditable() throws {
        guard !closed else { throw Self.closedError }
        guard snapshot.projection != nil else {
            throw HolosError.unavailable(snapshot.runProblem ?? "This meeting's speaker labels cannot be used.")
        }
        guard !isRelabelling else {
            throw HolosError.unavailable("Holos is labelling this meeting's speakers again; wait until it finishes.")
        }
    }

    private func requirePeople() throws {
        guard profiles != nil else { throw Self.noPeople }
    }

    /// Idle: nil. Otherwise what the first queued task is doing (a running one may say more, such as updating a
    /// voice sample).
    private func updateActivity() {
        guard let first = queue.first else {
            activity = nil
            return
        }
        if !first.started { activity = activityText(first) }
    }

    private func activityText(_ op: Operation) -> String? {
        switch op.kind {
        case .relabel: "Labelling speakers again…"
        case .exports: exportsPending ? "Updating the transcript files…" : nil
        case .reload: nil
        case .link(_, _, let learn, _), .assignPerson(_, _, _, let learn), .markSelf(_, let learn):
            learn && rememberVoices ? "Saving the name and learning the voice…" : "Saving…"
        case .confirmAll(let learn):
            learn && rememberVoices ? "Saving the names and learning the voices…" : "Saving…"
        case .edit, .undo: "Saving…"
        }
    }

    private func notify() { onChange?() }

    private func loadSnapshot() async throws -> SpeakerSessionSnapshot {
        let session = self.session
        let names = profileNames
        return try await Self.detached { try SpeakerSessionSnapshot.load(session: session, profileNames: names) }
    }

    private func reloadPeople() async {
        guard let store = profiles else { return }
        let loaded = await Self.detachedValue { Self.people(store: store) }
        people = loaded.people
        profileNames = loaded.names
        rememberVoices = loaded.remember
    }

    private static let closedError = HolosError.unavailable("The review window is closed.")
    private static let noPeople = HolosError.unavailable("People are not available here.")

    private static func noSpeaker(_ speakerID: String) -> HolosError {
        HolosError.invalidInput("There is no speaker \(speakerID) in this meeting's labels any more.")
    }

    private nonisolated static func newSpeakerID() -> String { "user:" + UUID().uuidString }

    /// Seconds before a sample clip starts in a long turn, and a clip's length.
    private static let clipLead = 0.25
    private static let clipSeconds = 4.0
    private static let previewCharacters = 60

    private nonisolated static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// linkProfile + rename of `speakerID` (a link, "This is me").
    private nonisolated static func linkBatch(_ speakerID: String) -> ([SpeakerEdit]) -> Bool {
        { batch in
            guard batch.count == 2,
                  case .linkProfile(let linked, _) = batch[0].action, linked == speakerID,
                  case .rename(let renamed, _) = batch[1].action, renamed == speakerID else { return false }
            return true
        }
    }

    /// linkProfile + rename pairs (Confirm All).
    private nonisolated static func confirmBatch(_ batch: [SpeakerEdit]) -> Bool {
        guard !batch.isEmpty, batch.count % 2 == 0 else { return false }
        return stride(from: 0, to: batch.count, by: 2).allSatisfy { index in
            guard case .linkProfile(let linked, _) = batch[index].action,
                  case .rename(let renamed, _) = batch[index + 1].action else { return false }
            return linked == renamed
        }
    }

    // MARK: - Loading (off the main actor)

    private struct Loaded: Sendable {
        var snapshot: SpeakerSessionSnapshot
        var people: [SpeakerProfile]
        var profileNames: [String: String]
        var rememberVoices: Bool
        var editedExports: Set<String>
    }

    private nonisolated static func load(session: URL, profiles: SpeakerProfileStore?) throws -> Loaded {
        let known = profiles.map { people(store: $0) } ?? (people: [], names: [:], remember: false)
        let snapshot = try SpeakerSessionSnapshot.load(session: session, profileNames: known.names)
        return Loaded(snapshot: snapshot, people: known.people, profileNames: known.names,
                      rememberVoices: known.remember, editedExports: editedExports(session: session))
    }

    private nonisolated static func people(store: SpeakerProfileStore)
        -> (people: [SpeakerProfile], names: [String: String], remember: Bool) {
        let remember: Bool
        do {
            remember = try store.load().rememberVoices
        } catch {
            log.error("Cannot read Remember voices: \(ProcessSpawner.logCategory(error), privacy: .public)")
            remember = false
        }
        return (VoiceProfileService.knownPeople(store: store), VoiceProfileService.profileNames(store: store), remember)
    }

    /// Names of the hand-edited exports moved aside so far (`exports/edited-*`).
    private nonisolated static func editedExports(session: URL) -> Set<String> {
        let folder = SessionPaths.exports(session)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return [] }
        return Set(names.filter { $0.hasPrefix("edited-") })
    }

    private nonisolated static func segmentIndex(_ transcript: Transcript) -> [String: TranscriptSegment] {
        var index: [String: TranscriptSegment] = [:]
        for segment in transcript.segments where index[segment.id] == nil { index[segment.id] = segment }
        return index
    }

    /// The exports' text of `spans`, reading only the segments they name.
    private nonisolated static func text(of spans: [WordSpan], segments: [String: TranscriptSegment],
                                         transcript: Transcript) -> String {
        var seen = Set<String>()
        let named = spans.compactMap { span -> TranscriptSegment? in
            guard seen.insert(span.segmentID).inserted else { return nil }
            return segments[span.segmentID]
        }
        let part = Transcript(id: transcript.id, createdAt: transcript.createdAt, source: transcript.source,
                              locale: transcript.locale, backend: transcript.backend, segments: named)
        return TranscriptExporter.text(of: spans, in: part)
    }

    private nonisolated static func detached<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: body).value
    }

    private nonisolated static func detachedValue<T: Sendable>(_ body: @escaping @Sendable () async -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: body).value
    }

    private nonisolated static func detachedResult<T: Sendable>(
        _ body: @escaping @Sendable () async throws -> T
    ) async -> Result<T, any Error> {
        await Task.detached(priority: .userInitiated) { () -> Result<T, any Error> in
            do {
                return .success(try await body())
            } catch {
                return .failure(error)
            }
        }.value
    }
}
