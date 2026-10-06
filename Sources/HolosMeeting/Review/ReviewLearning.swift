import Foundation
import HolosCore
import HolosSpeakers
import HolosStorage

/// What a meeting's word edits teach (docs/meeting-design.md §5.10, "Editing words"), worked out when a review window
/// closes from every word edited in the meeting's transcript as it is then: nothing is learned while editing, so
/// nothing has to be taken back, and an edit undone or reverted is not in the transcript. The meeting keeps what it
/// has taught (`review-learned.json`), so a close teaches only what is new: a correction deleted or changed in
/// Corrections is not taught again, and one whose write failed is taught at the next close.
enum ReviewLearning {
    /// review-learned.json: the corrections this meeting's review closes taught (their write succeeded).
    struct Taught: Codable, Equatable {
        var version: Int
        var corrections: [Correction]
    }

    /// What this meeting taught already; empty when nothing was. Throws when the record cannot be read (damaged, or
    /// written by a newer Voice is Local): nothing is taught then, rather than teaching again what was deleted.
    static func taught(session: URL) throws -> [Correction] {
        guard let data = try AtomicFile.readIfPresent(SessionPaths.reviewLearned(session), maxBytes: 4 << 20) else {
            return []
        }
        let record = try JSONDecoder().decode(Taught.self, from: data)
        guard record.version <= 1 else {
            throw HolosError.unavailable("What this meeting taught was recorded by a newer Voice is Local.")
        }
        return record.corrections
    }

    /// Adds `corrections` to what this meeting taught: read, merged, and written (atomically) under the meeting's speaker
    /// lock, so two closes (another Voice is Local running on the same folder) cannot lose each other's entries.
    static func recordTaught(adding corrections: [Correction], session: URL) throws {
        try SessionArchive.withSpeakerLock(at: session) {
            let taught = try Self.taught(session: session)
            let merged = taught + untaught(corrections, taught: taught)
            try AtomicFile.writeJSON(Taught(version: 1, corrections: merged), to: SessionPaths.reviewLearned(session))
        }
    }

    /// `corrections` this meeting has not taught: none with the same heard phrase (`CorrectionList.key`) and meaning.
    static func untaught(_ corrections: [Correction], taught: [Correction]) -> [Correction] {
        let known = Set(taught.map { "\(CorrectionList.key($0.heard))\u{1f}\($0.meant)" })
        return corrections.filter { !known.contains("\(CorrectionList.key($0.heard))\u{1f}\($0.meant)") }
    }

    /// The `reviewEdit` fixes of `transcript` as edits: what the recognizer wrote, the words' shown text, and the shown
    /// words around them as context. In transcript order (segments by start, then track; fixes by position). An edit
    /// back to what the recognizer wrote (a Revert) is left out. `sameTurn(segmentID, word, neighbour)` says whether a
    /// neighbouring word may be context: shown in the same turn as the edited word (not another speaker's, not hidden
    /// as echo), as an edit itself may only take in such words. Without it, no neighbour is.
    static func edits(in transcript: Transcript,
                      sameTurn: (_ segmentID: String, _ word: Int, _ neighbour: Int) -> Bool) -> [ReviewWordEdit] {
        let ordered = transcript.segments.sorted { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        var edits: [ReviewWordEdit] = []
        for segment in ordered {
            let words = WordTiming.effectiveWords(of: segment)
            let utf16 = Array(segment.text.utf16)
            let fixes = (segment.fixes ?? []).filter { fix in
                fix.kind == .reviewEdit && fix.first >= 0 && fix.first < fix.end && fix.end <= words.count
            }.sorted { $0.first < $1.first }
            // Edits side by side in one turn ("bull" → "pull", then "requested" → "request") are one span: learned
            // apart, each would take the other's corrected word as what was heard beside it ("pull requested"), and
            // neither rule would match what the recognizer wrote ("bull requested").
            var spans: [[TranscriptWordFix]] = []
            for fix in fixes {
                if let last = spans.last?.last, last.end == fix.first, sameTurn(segment.id, last.end - 1, fix.first) {
                    spans[spans.count - 1].append(fix)
                } else {
                    spans.append([fix])
                }
            }
            for span in spans {
                guard let first = span.first?.first, let end = span.last?.end,
                      let meant = TranscriptWordEdit.shownText(of: segment, first: first, end: end) else { continue }
                // What the recognizer wrote over the span: each edit's `heard`, with the text between them as it is
                // (no space where the words had none).
                var written = TranscriptWordEdit.cleaned(span[0].heard)
                for (previous, next) in zip(span, span.dropFirst()) {
                    // Shown extents meet but for the whitespace between them: none means the words had no space.
                    let end = TranscriptWordEdit.extent(of: previous.first..<previous.end, words: words, utf16: utf16)
                    let start = TranscriptWordEdit.extent(of: next.first..<next.end, words: words, utf16: utf16)
                    let spaced = end.isEmpty || start.isEmpty || end.upperBound != start.lowerBound
                    written += (spaced ? " " : "") + TranscriptWordEdit.cleaned(next.heard)
                }
                let heard = TranscriptWordEdit.cleaned(written)
                let shown = TranscriptWordEdit.cleaned(meant)
                guard heard != shown else { continue }
                let before = first > 0 && sameTurn(segment.id, first, first - 1)
                    ? TranscriptWordEdit.shownText(of: segment, first: first - 1, end: first) : nil
                let after = end < words.count && sameTurn(segment.id, end - 1, end)
                    ? TranscriptWordEdit.shownText(of: segment, first: end, end: end + 1) : nil
                edits.append(ReviewWordEdit(heard: heard, meant: shown, before: before, after: after))
            }
        }
        return edits
    }

    /// The corrections `edits` teach (`teach`: the app's rule, `TranscriptEditLearning`), in order, each heard phrase
    /// (`CorrectionList.key`) once: the first edit teaching it, in the meeting's order, gives it.
    static func corrections(_ edits: [ReviewWordEdit], teach: (ReviewWordEdit) -> [Correction]) -> [Correction] {
        var seen = Set<String>()
        var result: [Correction] = []
        for edit in edits {
            for correction in teach(edit) {
                let key = CorrectionList.key(correction.heard)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                result.append(correction)
            }
        }
        return result
    }
}
