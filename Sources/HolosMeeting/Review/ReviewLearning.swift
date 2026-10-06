import Foundation
import HolosCore

/// What a review window's word edits have taught, and what corrections.json should hold for it (docs/meeting-design.md
/// §5.10, "Editing words"). The list holds one correction per heard phrase (its key, `CorrectionList.key`), while
/// several edits of one window may teach the same key, so nothing is pushed or popped: the wanted state is worked out
/// again from the window's edits after every change.
///
/// - Every edit that taught something is kept, in the order the edits were made, active or not: an undo removes it, a
///   Revert of its words makes it inactive, and the Revert's undo makes it active again.
/// - For each key the window touched, the value it had before the window first changed it is kept (its baseline, or
///   none).
/// - The wanted value of a key is that of the most recent active edit teaching it, else its baseline.
///
/// Pure. `ReviewSession` hands `wanted` to the app (`ReviewSession.syncCorrections`), which writes it, and keeps it
/// owed (`needsSync`) until a write works.
struct ReviewLearning: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let id: UUID
        let segmentID: String
        /// Its words' stored indices in the segment, kept up to date through every later word move.
        var words: Range<Int>
        /// What it teaches, by key.
        let corrections: [String: Correction]
        var active = true

        /// Whether its words are among `replaced` (word indices before the move that replaces them).
        func belongs(to replaced: Range<Int>, in segmentID: String) -> Bool {
            guard segmentID == self.segmentID else { return false }
            return words.isEmpty ? replaced.contains(words.lowerBound) || words.lowerBound == replaced.upperBound
                : words.overlaps(replaced)
        }

        /// Its words after `move`: shifted when after the replaced words; the replacement (with whatever of its own
        /// words lay outside) when some of them were replaced.
        func moved(by move: ReviewWordMove) -> Entry {
            guard move.segmentID == segmentID, words.upperBound > move.replaced.lowerBound else { return self }
            let delta = move.replacement.count - move.replaced.count
            var result = self
            if words.lowerBound >= move.replaced.upperBound {
                result.words = (words.lowerBound + delta)..<(words.upperBound + delta)
                return result
            }
            let lower = words.lowerBound < move.replaced.lowerBound ? words.lowerBound : move.replacement.lowerBound
            let upper = words.upperBound > move.replaced.upperBound ? words.upperBound + delta
                : move.replacement.upperBound
            result.words = lower..<max(lower, upper)
            return result
        }
    }

    /// In the order the edits were made.
    private(set) var entries: [Entry] = []
    /// Each key's value before the window first changed it (nil: it had none).
    private(set) var baseline: [String: Correction?] = [:]
    /// Keys taught whose baseline is not known yet (no write has worked since): read just before the next write.
    private(set) var uncaptured: Set<String> = []
    /// `wanted` changed since corrections.json was last brought in step with it.
    var needsSync = false

    /// An edit of words `words` (indices after it) of `segmentID` taught `corrections`; returns its entry's ID, nil when
    /// it taught nothing.
    mutating func add(_ corrections: [Correction], segmentID: String, words: Range<Int>) -> UUID? {
        var byKey: [String: Correction] = [:]
        for correction in corrections {
            let key = CorrectionList.key(correction.heard)
            guard !key.isEmpty else { continue }
            byKey[key] = correction
        }
        guard !byKey.isEmpty else { return nil }
        let entry = Entry(id: UUID(), segmentID: segmentID, words: words, corrections: byKey)
        entries.append(entry)
        for key in byKey.keys where !baseline.keys.contains(key) { uncaptured.insert(key) }
        needsSync = true
        return entry.id
    }

    /// The edit that made entry `id` was undone.
    mutating func remove(_ id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        needsSync = true
    }

    /// A Revert of words `replaced` of `segmentID`: the active entries of those very words become inactive; returns
    /// their IDs, for its undo.
    mutating func deactivate(_ replaced: Range<Int>, in segmentID: String) -> [UUID] {
        var ids: [UUID] = []
        for index in entries.indices where entries[index].active
            && entries[index].belongs(to: replaced, in: segmentID) {
            entries[index].active = false
            ids.append(entries[index].id)
        }
        if !ids.isEmpty { needsSync = true }
        return ids
    }

    /// A Revert was undone: the entries it made inactive are active again, where they were in the order.
    mutating func activate(_ ids: [UUID]) {
        let wanted = Set(ids)
        for index in entries.indices where wanted.contains(entries[index].id) { entries[index].active = true }
        if !ids.isEmpty { needsSync = true }
    }

    /// Words moved (an edit or an undo).
    mutating func move(_ move: ReviewWordMove) {
        entries = entries.map { $0.moved(by: move) }
    }

    /// What corrections.json should hold for each key the window touched (nil: no correction for it). A key whose
    /// baseline is not known and that no active edit teaches is left out: it was never written.
    var wanted: [String: Correction?] {
        var keys = Set(baseline.keys)
        for entry in entries { keys.formUnion(entry.corrections.keys) }
        var result: [String: Correction?] = [:]
        for key in keys {
            if let latest = entries.last(where: { $0.active && $0.corrections[key] != nil }) {
                result[key] = latest.corrections[key]
            } else if let known = baseline[key] {
                result[key] = known
            }
        }
        return result
    }

    /// corrections.json was brought in step with `wanted`; `before` holds the values the `uncaptured` keys had just
    /// before (their baselines).
    mutating func synced(capturing before: [String: Correction?]) {
        for key in uncaptured { baseline[key] = .some(before[key] ?? nil) }
        uncaptured.removeAll()
        needsSync = false
    }
}
