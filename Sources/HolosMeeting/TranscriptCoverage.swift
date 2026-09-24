import Foundation
import HolosCore

/// Joins live transcription with a replay of only the audio it missed (docs/meeting-design.md §4.6). Pure; the stop
/// path uses it after a recording, and recovery (PR3) after a crash, so one dropped frame never throws away hours of
/// live words.
public enum TranscriptCoverage {
    /// End of the last live segment, capped at `behindFrom` (the earliest transcriptionBehind.from for the
    /// track). 0 when there are no live segments.
    public static func coverageEnd(live: [TranscriptSegment], behindFrom: Double?) -> Double {
        let end = live.map(\.end).filter(\.isFinite).max() ?? 0
        guard let behindFrom, behindFrom.isFinite else { return max(0, end) }
        return max(0, min(end, behindFrom))
    }

    /// Keeps live words that start before `coverageEnd` and replayed words that start at or after it.
    /// A segment cut at a word boundary keeps its ID for the first part and gets a new UUID for the second;
    /// text is cut at the kept words' UTF-16 offsets. Untimed segments are kept or dropped whole by midpoint.
    /// The result is ordered by start time (then track).
    public static func merge(live: [TranscriptSegment], replayed: [TranscriptSegment],
                             coverageEnd: Double) -> [TranscriptSegment] {
        var merged: [TranscriptSegment] = []
        for segment in live {
            if segment.words.isEmpty {
                if (segment.start + segment.end) / 2 < coverageEnd { merged.append(segment) }
            } else if let kept = prefix(of: segment, before: coverageEnd) {
                merged.append(kept)
            }
        }
        for segment in replayed {
            if segment.words.isEmpty {
                if (segment.start + segment.end) / 2 >= coverageEnd { merged.append(segment) }
            } else if let kept = suffix(of: segment, from: coverageEnd) {
                merged.append(kept)
            }
        }
        return merged.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if a.start != b.start { return a.start < b.start }
            if (a.track ?? "") != (b.track ?? "") { return (a.track ?? "") < (b.track ?? "") }
            return left.offset < right.offset
        }.map(\.element)
    }

    // MARK: - Cutting

    /// The words starting before `end`, keeping the segment's ID; nil when none do.
    private static func prefix(of segment: TranscriptSegment, before end: Double) -> TranscriptSegment? {
        let kept = segment.words.filter { $0.start < end }
        if kept.count == segment.words.count { return segment }
        guard let cut = kept.map({ $0.utf16Offset + $0.utf16Length }).max() else { return nil }
        var part = segment
        if let head = text(segment.text, from: 0, to: cut) {
            // Offsets are relative to the start of the text, which the first part keeps.
            part.text = trimmingTrailingWhitespace(head)
            part.words = kept
        } else {
            part.words = rebased(kept)
            part.text = kept.map(\.text).joined(separator: " ")
        }
        part.end = max(part.start, min(segment.end, kept.map(\.end).max() ?? segment.end))
        return part
    }

    /// The words starting at or after `start`, under a new ID; nil when none do.
    private static func suffix(of segment: TranscriptSegment, from start: Double) -> TranscriptSegment? {
        let kept = segment.words.filter { $0.start >= start }
        if kept.count == segment.words.count { return segment }
        guard let cut = kept.map(\.utf16Offset).min() else { return nil }
        var part = segment
        part.id = UUID().uuidString
        if let tail = text(segment.text, from: cut, to: segment.text.utf16.count) {
            part.text = trimmingTrailingWhitespace(tail)
            part.words = kept.map { word in
                var moved = word
                moved.utf16Offset -= cut
                return moved
            }
        } else {
            part.words = rebased(kept)
            part.text = kept.map(\.text).joined(separator: " ")
        }
        part.start = min(segment.end, max(segment.start, kept.map(\.start).min() ?? segment.start))
        return part
    }

    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex, text[text.index(before: end)].isWhitespace { end = text.index(before: end) }
        return String(text[..<end])
    }

    /// `text` between two UTF-16 offsets, or nil when either offset is out of range or not on a character
    /// boundary.
    private static func text(_ text: String, from start: Int, to end: Int) -> String? {
        let utf16 = text.utf16
        guard start >= 0, start <= end, end <= utf16.count else { return nil }
        let lower = utf16.index(utf16.startIndex, offsetBy: start)
        let upper = utf16.index(utf16.startIndex, offsetBy: end)
        guard let from = lower.samePosition(in: text), let to = upper.samePosition(in: text) else { return nil }
        return String(text[from..<to])
    }

    /// Offsets of `words` in the text made by joining them with single spaces.
    private static func rebased(_ words: [TimedWord]) -> [TimedWord] {
        var offset = 0
        return words.map { word in
            var moved = word
            moved.utf16Offset = offset
            moved.utf16Length = word.text.utf16.count
            offset += moved.utf16Length + 1
            return moved
        }
    }
}
