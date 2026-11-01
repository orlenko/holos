import Foundation

/// When each sentence of a reading's text is spoken, for the text that follows the voice.
///
/// A part's start in the finished file is exact: its manifest keeps every part's rendered duration, and the silences
/// before parts follow `ReadingPart.silenceBefore`. Inside a part, a sentence's time is estimated in proportion to its
/// place in the part's text, since a renderer reports no word times.
///
/// Invariants:
/// 1. A timeline exists only when every part has a duration and its range of the text hashes to what was rendered, so
///    a highlight never follows another text than the one spoken.
/// 2. `spans` are in reading order, with `start` never decreasing, and no span is empty.
public struct ReadingTimeline: Sendable, Equatable {
    public struct Span: Sendable, Equatable {
        /// Seconds into the finished file.
        public let start: Double
        /// UTF-16 range in the text, without the white space around the sentence.
        public let range: NSRange
    }

    public let spans: [Span]

    /// Nil when `manifest` does not describe `text` (invariant 1) or nothing in it is spoken.
    public init?(manifest: ReadingManifest, text: String) {
        let source = text as NSString
        var spans: [Span] = []
        var time = 0.0
        for part in manifest.parts {
            let range = NSRange(location: part.sourceUTF16Offset, length: part.sourceUTF16Length)
            guard let duration = part.duration, duration.isFinite, duration >= 0, range.location >= 0, range.length > 0,
                  range.location <= source.length - range.length,
                  sha256(Data(source.substring(with: range).utf8)) == part.textSHA256 else { return nil }
            time += part.silenceBefore(manifest.format)
            let partStart = time
            source.enumerateSubstrings(in: range, options: [.bySentences, .substringNotRequired]) { _, sentence, _, _ in
                guard let trimmed = Self.trimmed(sentence, in: source) else { return }
                let share = Double(trimmed.location - range.location) / Double(range.length)
                spans.append(Span(start: partStart + duration * share, range: trimmed))
            }
            time += duration
        }
        guard !spans.isEmpty else { return nil }
        self.spans = spans
    }

    /// The sentence being spoken at `time`: in the silence after a sentence, still that one; before the first, the first.
    public func span(at time: Double) -> Span? {
        guard time.isFinite else { return nil }
        var low = 0, high = spans.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if spans[middle].start <= time { low = middle } else { high = middle - 1 }
        }
        return spans[low]
    }

    /// The timeline of a made reading, from the manifest its render cache keeps, read off the main actor (a cache can be
    /// on a slow drive and a book has thousands of parts). Nil without a cache or a manifest that fits `text`.
    public static func load(for entry: ReadingEntry, text: String) async -> ReadingTimeline? {
        guard let cache = entry.cache else { return nil }
        let folder = ReadingOutput.fileURL(keepingSpelling: cache, isDirectory: true)
        return await Task.detached(priority: .userInitiated) {
            ReadingResumeVoice.manifest(in: folder).flatMap { ReadingTimeline(manifest: $0, text: text) }
        }.value
    }

    private static func trimmed(_ range: NSRange, in source: NSString) -> NSRange? {
        func isSpace(_ index: Int) -> Bool {
            Unicode.Scalar(source.character(at: index)).map(CharacterSet.whitespacesAndNewlines.contains) ?? false
        }
        var start = range.location, end = NSMaxRange(range)
        while start < end, isSpace(start) { start += 1 }
        while end > start, isSpace(end - 1) { end -= 1 }
        return start < end ? NSRange(location: start, length: end - start) : nil
    }
}
