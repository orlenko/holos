import Foundation
import HolosCore
import HolosSpeakers

/// The sentences `SpeakerEditCommand` reports for a change. They name speakers and people (the user's own labels);
/// they are for the person running the command and are never logged.
extension SpeakerEditCommand {
    /// One sentence for a change: "Renamed system:S2 to Maria." Speakers are described on `before`, the labels the
    /// change was made on; a speaker or turn the change created is described on `after` when given. `editID` is the
    /// journal line's ID when the change is already saved (it names a split's second part). `people` (profile ID →
    /// name) names the person of a link or rejection.
    static func describe(_ action: SpeakerEditAction, before: SpeakerProjection, after: SpeakerProjection?,
                         editID: String? = nil, people: [String: String] = [:]) -> String {
        func person(_ id: String) -> String { people[id] ?? "person \(id)" }
        func speaker(_ id: String) -> String {
            let found = before.speakers.first { $0.id == id } ?? after?.speakers.first { $0.id == id }
            return found.map { "\($0.id) (\($0.label))" } ?? id
        }
        switch action {
        case .rename(let speakerID, let name):
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return "Renamed \(speakerID) to \(name)."
            }
            return "Cleared the name of \(speakerID)."
        case .merge(let from, let into):
            return "Merged \(speaker(from)) into \(speaker(into))."
        case .reassignTurns(let turnIDs, let to):
            return "Assigned \(turnList(turnIDs)) to \(to.map(speaker) ?? "Unknown speaker")."
        case .newSpeaker(let speakerID, _, let turnIDs):
            return "Assigned \(turnList(turnIDs)) to a new speaker, \(speaker(speakerID))."
        case .splitTurn(let turnID, let word):
            let part: ProjectedTurn?
            if let editID {
                // Already saved: the part is in `before` (undo), with the ID the split gave it.
                part = before.turns.first { $0.id == "\(turnID)/\(editID)" }
            } else {
                let beforeIDs = Set(before.turns.map(\.id))
                part = after?.turns.first { $0.id.hasPrefix("\(turnID)/") && !beforeIDs.contains($0.id) }
            }
            let head = before.turns.first { $0.id == turnID }
            // Before the split the word is in the turn; after it, it follows the words the turn kept.
            let position = wordNumber(word, in: head) ?? (editID == nil ? nil : head.map { wordCount($0) + 1 })
            return "Split \(turnID)" + (position.map { " before its word \($0)" } ?? "")
                + (part.map { "; the second part is \($0.id) from \(TimeFormat.clock($0.start))" } ?? "") + "."
        case .excludeFromEnrollment(let turnIDs):
            return "Excluded \(turnList(turnIDs)) from voice learning."
        case .linkProfile(let speakerID, let profileID):
            return "Linked \(speaker(speakerID)) to \(person(profileID))."
        case .rejectProfile(let speakerID, let profileID):
            return "Marked \(speaker(speakerID)) as not \(person(profileID))."
        case .revert(let editID):
            return "Reverted edit \(editID)."
        }
    }

    /// "T4", "T4 and T5", "T4, T5, and T6", or "12 turns (T4, T5, T6, …)".
    static func turnList(_ ids: [String]) -> String {
        switch ids.count {
        case 0: return "no turns"
        case 1: return ids[0]
        case 2: return "\(ids[0]) and \(ids[1])"
        case 3...5: return ids.dropLast().joined(separator: ", ") + ", and \(ids[ids.count - 1])"
        default: return "\(ids.count) turns (\(ids.prefix(3).joined(separator: ", ")), …)"
        }
    }

    /// What happened to a voice that was asked to be learned.
    static func voiceNote(profile: SpeakerProfile, database: SpeakerProfileDatabase, snapshot: SpeakerSessionSnapshot,
                          extractorAvailable: Bool) -> String {
        if let sample = profile.samples.first(where: { $0.sessionID == snapshot.manifest.id }) {
            return "Learned \(profile.displayName)'s voice from this meeting "
                + "(\(TimeFormat.duration(sample.speechSeconds)) of speech)."
                + (sample.weak ? " It is short, so it can only give suggestions." : "")
        }
        if !database.rememberVoices {
            return "Remember voices is off, so no voice was learned. Turn it on with voiceislocal people remember on."
        }
        if snapshot.audioDeleted { return VoiceProfileService.audioDeletedNote }
        if !extractorAvailable { return modelsMissing }
        if let model = profile.embeddingModel, let run = snapshot.run?.engine?.embeddingModel, model != run {
            return "\(profile.displayName)'s voice samples come from other speaker models, so this one can't be "
                + "added. Forget their samples first (voiceislocal people forget)."
        }
        return "No turn of this speaker was long and clear enough (2 s or more, without overlap) to learn the voice."
    }

    private static func wordCount(_ turn: ProjectedTurn) -> Int {
        turn.spans.reduce(0) { $0 + max(0, $1.end - $1.first) }
    }

    /// The 1-based position of `word` among the turn's words.
    private static func wordNumber(_ word: WordRef, in turn: ProjectedTurn?) -> Int? {
        guard let turn else { return nil }
        var position = 0
        for span in turn.spans {
            for index in span.first..<max(span.first, span.end) {
                position += 1
                if span.segmentID == word.segmentID, index == word.word { return position }
            }
        }
        return nil
    }
}
