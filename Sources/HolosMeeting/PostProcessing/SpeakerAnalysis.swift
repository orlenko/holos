import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage
import os

/// Stages 2–6 of the post-processor (docs/meeting-design.md §4.7): track policies, the head decision, the disk
/// check, and building and publishing the run. `MeetingPostProcessor` runs them in order; rendering and diarization
/// are driven from there because they report progress.
enum SpeakerAnalysis {
    private static let log = Logger(subsystem: "ca.orlenko.holos.app", category: "postprocess")

    // MARK: - Messages (user-facing; never transcript text)

    static let modelsMissing = "Speaker models are not installed. Install them from Setup, or run holos setup --speakers."
    static let modelsMissingRecord = "No speaker labels: speaker models are not installed. Install them from Setup, or run holos setup --speakers."
    static let modelsMissingKeptLabels = "Kept the earlier speaker labels: speaker models are not installed. Install them from Setup, or run holos setup --speakers."
    static let editedHead = "Speaker labels were edited; relabel with --force (names carry over)."
    static let noDiskSpace = "Not enough disk space to label speakers. Free some space, then use Label Speakers."
    static let audioDeleted = "The recording's audio was deleted, so speakers can't be labelled."
    static let noTrackToLabel = "No track needs speaker labels."
    static let previousUnreadable = "The previous speaker labels could not be read, so their names were not carried over."

    /// The channel speaker of a call's microphone when nobody else is in the room.
    static let meSpeakerID = "mic:me"
    static let meName = "Me"

    // MARK: - Stage 2: track policies

    struct TrackPlan: Sendable, Equatable {
        var track: String
        var policy: TrackPolicy

        var isDiarized: Bool {
            if case .diarized = policy { return true }
            return false
        }
    }

    /// One plan per track that has audio or words ("mic" before "system"). A track without words is skipped; a track
    /// is diarized if it is the system track, the meeting is in person, or others are in the room; otherwise (a
    /// call's microphone) every word is "Me". Segments without a track (older transcripts) count for the only track.
    static func trackPlans(transcript: Transcript, manifest: SessionManifest, meeting: MeetingInfo,
                           othersInRoom: Bool) -> [TrackPlan] {
        let known = ["mic", "system"]
        var present = Set(manifest.chunks.map(\.track))
        for segment in transcript.segments { if let track = segment.track { present.insert(track) } }
        let tracks = known.filter(present.contains)
        let untrackedOwner = tracks.count == 1 ? tracks.first : nil
        return tracks.map { track in
            let hasWords = transcript.segments.contains { segment in
                (segment.track == track || (segment.track == nil && untrackedOwner == track))
                    && !WordTiming.effectiveWords(of: segment).isEmpty
            }
            guard hasWords else { return TrackPlan(track: track, policy: .skipped(reason: "No words on this track.")) }
            if track == "system" || meeting.mode == .inPerson || othersInRoom {
                return TrackPlan(track: track, policy: .diarized)
            }
            return TrackPlan(track: track, policy: .channel(speakerID: meSpeakerID, displayName: meName))
        }
    }

    /// `options.speakers`, else meeting.json's `expectedSpeakers` n: `minimum n − 1, maximum n + 1` when one track
    /// is diarized. With two diarized tracks the people are split between them in an unknown way, so each track
    /// only gets a maximum: `options.speakers`' `exactly` or `maximum` (its `minimum` alone gives no hint), or
    /// n + 1.
    static func speakerHint(options: PostProcessingOptions, meeting: MeetingInfo,
                            diarizedTracks: Int) -> SpeakerCountHint? {
        if let hint = options.speakers {
            guard diarizedTracks > 1 else { return hint }
            return (hint.exactly ?? hint.maximum).map { SpeakerCountHint(maximum: $0) }
        }
        guard let expected = meeting.expectedSpeakers, expected > 0 else { return nil }
        if diarizedTracks <= 1 { return SpeakerCountHint(minimum: max(1, expected - 1), maximum: expected + 1) }
        return SpeakerCountHint(maximum: expected + 1)
    }

    /// Alignment settings for the meeting (PR11 turns on the echo filter for calls here).
    static func alignmentParameters(meeting: MeetingInfo) -> AlignmentParameters { .v1 }

    // MARK: - Stage 4: disk check

    /// Bytes of 16 kHz mono Int16 audio per second (115.2 MB per hour).
    static let renderBytesPerSecond = 32_000.0
    static let renderHeadroomBytes: Int64 = 1_000_000_000

    /// Rendering is allowed only if free ≥ render bytes + 1 GB (§4.5 `DiskPolicy.renderCheck`, which PR2a adds to
    /// the recorder; the post-processor merges before it and keeps this rule here). `renderSeconds` is the total
    /// length of every render.
    static func renderAllowed(freeBytes: Int64, renderSeconds: Double) -> Bool {
        guard renderSeconds.isFinite, renderSeconds >= 0 else { return false }
        let needed = renderSeconds * renderBytesPerSecond + Double(renderHeadroomBytes)
        return Double(freeBytes) >= needed
    }

    // MARK: - Stage 3: the head decision

    /// The current head as the relabel decision and carry-over see it.
    struct HeadState {
        var runID: String
        /// Nil when the run file is missing or damaged.
        var run: DiarizationRun?
        /// The head with its edits, when its run and transcript are readable and match.
        var projection: SpeakerProjection?
        /// Applied edits (all edits of the run when there is no projection).
        var hasEdits: Bool
        /// The head was built from `transcript`.
        var sameTranscript: Bool

        /// Relabelling would replace edited labels of this very transcript.
        func needsForce(_ force: Bool) -> Bool { sameTranscript && hasEdits && !force }

        /// The head's run ID when the exports can still show it for this transcript (it was built from it and its
        /// spans are valid), so a run that keeps it can report it.
        var usableRunID: String? { sameTranscript && projection != nil ? runID : nil }
    }

    /// Nil when there is no head. A head whose run or transcript is missing or damaged still counts (it is
    /// replaced, without carry-over); a file that cannot be read now, or one from a newer Holos, throws.
    static func headState(session: URL, transcript: Transcript) throws -> HeadState? {
        guard let head = try SessionSpeakerStore.readHead(session: session) else { return nil }
        let edits = try SessionSpeakerStore.readEdits(session: session).edits
        let run: DiarizationRun
        do {
            run = try SessionSpeakerStore.readRun(id: head.runID, session: session)
        } catch let error where SessionFiles.isDamage(error) {
            log.error("Head run \(head.runID, privacy: .public) is unusable: \(error.localizedDescription, privacy: .private)")
            return HeadState(runID: head.runID, run: nil, projection: nil,
                             hasEdits: edits.contains { $0.baseRunID == head.runID }, sameTranscript: false)
        }
        let sameTranscript = run.transcriptID == transcript.id
        var runTranscript: Transcript? = sameTranscript ? transcript : nil
        if !sameTranscript {
            do {
                runTranscript = try SessionFiles.transcript(id: run.transcriptID, session: session)
            } catch let error where SessionFiles.isDamage(error) {
                log.error("The head run's transcript is unusable: \(error.localizedDescription, privacy: .private)")
            }
        }
        var projection: SpeakerProjection?
        if let runTranscript, SpeakerSessionSnapshot.spanProblem(run: run, transcript: runTranscript) == nil {
            projection = SpeakerProjection.make(run: run, transcript: runTranscript, edits: edits, recognition: nil,
                                                profileNames: [:])
        }
        let hasEdits = projection.map { !$0.appliedEditIDs.isEmpty } ?? edits.contains { $0.baseRunID == run.id }
        return HeadState(runID: run.id, run: run, projection: projection, hasEdits: hasEdits,
                         sameTranscript: sameTranscript)
    }

    // MARK: - Stage 6: publishing the run

    struct Publication {
        var run: DiarizationRun
        /// Names, links, and rejections carried from the replaced head; nil when there was nothing to carry from.
        var carry: SpeakerCarryOver.Result?
        /// A head was replaced whose labels could not be read, so nothing was carried.
        var previousUnreadable: Bool
    }

    enum PublishOutcome {
        case published(Publication)
        /// The head was edited after the decision in stage 3 (or before, without `force`); it stays.
        case keptEditedHead(runID: String?)
    }

    /// Under the speaker lock: checks the head again (an editor may have written meanwhile), then publishes the run
    /// (`writeRun`), the voice data only when `writeVoiceData` (hidden `forceVoiceData`, evaluation sessions; never
    /// for normal meetings, §4.10), the carry-over edits (source "carry", the new run as base, one batch), and last
    /// `speakers/head.json`, so a crash before that leaves the old head in place. The lock is released on return.
    static func publish(_ built: SpeakerRunBuilder.Result, session: URL, transcript: Transcript, force: Bool,
                        writeVoiceData: Bool) throws -> PublishOutcome {
        try SessionArchive.withSpeakerLock(at: session) {
            let state = try headState(session: session, transcript: transcript)
            if let state, state.needsForce(force) { return .keptEditedHead(runID: state.usableRunID) }
            try SessionSpeakerStore.writeRun(built.run, session: session)
            if writeVoiceData, let voiceData = built.voiceData {
                try SessionSpeakerStore.writeVoiceData(voiceData, session: session)
            }
            var carry: SpeakerCarryOver.Result?
            if let projection = state?.projection {
                let result = SpeakerCarryOver.carry(from: projection, to: built.run)
                if !result.actions.isEmpty {
                    try SessionSpeakerStore.appendEdits(
                        carryEdits(result.actions, run: built.run, transcript: transcript), session: session)
                }
                carry = result
            }
            try SessionSpeakerStore.writeHead(SpeakerHead(runID: built.run.id), session: session)
            let unreadable = state.map { $0.projection == nil && $0.hasEdits } ?? false
            return .published(Publication(run: built.run, carry: carry, previousUnreadable: unreadable))
        }
    }

    /// Journal lines for carried actions: each carries the fingerprint of the new run's state before it, like an
    /// editor batch, and all share one batch ID.
    static func carryEdits(_ actions: [SpeakerEditAction], run: DiarizationRun, transcript: Transcript) -> [SpeakerEdit] {
        var view = SpeakerProjection.make(run: run, transcript: transcript, edits: [], recognition: nil, profileNames: [:])
        let batchID = UUID().uuidString
        return actions.map { action in
            let id = UUID().uuidString
            let expected = view.fingerprint(for: action)
            view = view.applying(action, editID: id)
            return SpeakerEdit(id: id, baseRunID: run.id, source: "carry", action: action, expected: expected,
                               batchID: batchID)
        }
    }

    // MARK: - Messages

    /// "Kept 8 names; 1 name could not be matched and 12 turn-level changes were not carried."; nil when there is
    /// nothing to say.
    static func carryMessage(_ carry: SpeakerCarryOver.Result) -> String? {
        let kept = Set(carry.actions.compactMap(speakerID(of:))).count
        var rest: [String] = []
        if !carry.unmatchedSpeakers.isEmpty {
            let count = carry.unmatchedSpeakers.count
            rest.append("\(count) \(count == 1 ? "name" : "names") could not be matched")
        }
        if carry.droppedTurnEdits > 0 {
            let count = carry.droppedTurnEdits
            rest.append("\(count) turn-level \(count == 1 ? "change was" : "changes were") not carried")
        }
        let keptText = kept > 0 ? "Kept \(kept) \(kept == 1 ? "name" : "names")" : nil
        switch (keptText, rest.isEmpty) {
        case (nil, true): return nil
        case (let keptText?, true): return keptText + "."
        case (let keptText?, false): return keptText + "; " + rest.joined(separator: " and ") + "."
        case (nil, false):
            let text = rest.joined(separator: " and ") + "."
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    /// "Labelled 3 speakers in 42 turns.", or with `showingRun` "Labelled 3 speakers in 42 turns (run 5C1D7E2A…)."
    static func labelledMessage(_ run: DiarizationRun, showingRun: Bool = false) -> String {
        let suffix = showingRun ? " (run \(run.id.prefix(8))…)." : "."
        guard !run.turns.isEmpty else { return "The transcript has no words to label" + suffix }
        let speakers = run.speakers.count
        guard speakers > 0 else { return "No speakers were found in the audio" + suffix }
        let turns = run.turns.count
        return "Labelled \(speakers) \(speakers == 1 ? "speaker" : "speakers") in \(turns) "
            + "\(turns == 1 ? "turn" : "turns")" + suffix
    }

    private static func speakerID(of action: SpeakerEditAction) -> String? {
        switch action {
        case .rename(let speakerID, _), .linkProfile(let speakerID, _), .rejectProfile(let speakerID, _): speakerID
        default: nil
        }
    }

    /// "microphone" or "system audio", for progress text.
    static func trackLabel(_ track: String) -> String {
        track == "system" ? "system audio" : track == "mic" ? "microphone" : track
    }
}
