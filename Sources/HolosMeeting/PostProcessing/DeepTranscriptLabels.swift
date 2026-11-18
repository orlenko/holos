import Foundation
import HolosCore
import HolosSpeakers

/// Speaker labels and prompt roll-call lists Whisper writes into a passage that nobody said ("Jane Doe: Yes.",
/// "Jane Doe- Yes.", "Jane Doe, Ph.D.: …", "Jane Doe-Smith, Omar, Lena, …"), as the transcripts it learned from and
/// the vocabulary prompt put them (docs/meeting/deep-transcription.md §4.16). Pure.
extension DeepTranscriptGuards {
    /// The most words one name or title in a label has, its colon or dash word included ("Dr. Jane Q. Doe:").
    public static let labelMaxWords = DeepTranscribedLabel.labelMaxWords
    /// How far around a label the recorded transcript's words are looked for: a label whose words are there was said.
    public static let labelReferenceSeconds = 2.0

    /// `segment` without the speaker labels and prompt roll-call lists the model invented in it, and how many there
    /// were; nil when nothing else was in it. A speaker label ends in ":" (1 to `labelMaxWords` words per
    /// comma-separated item) or "-" (2 to `labelMaxWords` name words, or a name joined by "-" to the next word), at the
    /// start of the passage or after a word ending a sentence, and stays when the recorded transcript (`spoken`) has
    /// each of its words but titles on the same track within `labelReferenceSeconds` ("Question: …"). A colon-less
    /// comma-separated roll-call list of names at the start of a passage stays when the recorded transcript has any of
    /// its words there. Without a recorded transcript the shape alone decides. A segment without word timings is looked
    /// at by its text.
    static func withoutLabels(_ segment: DeepHeardSegment, spoken: SpokenWords?)
        -> (segment: DeepHeardSegment?, labels: Int) {
        let timed = !segment.words.isEmpty
        var words = timed ? segment.words : segment.text.split(whereSeparator: \.isWhitespace).map {
            DeepTranscribedWord(text: " " + $0, start: segment.start, end: segment.end)
        }
        var labels = 0
        var index = 0
        while index < words.count {
            if let found = DeepTranscribedLabel.match(words, from: index),
               !said(words[index...found.end], isList: found.isList, track: segment.track, spoken: spoken) {
                if found.unhyphenateNext, found.end + 1 < words.count {
                    words[found.end + 1].text = DeepTranscribedLabel.unhyphenated(words[found.end + 1].text)
                }
                words.removeSubrange(index...found.end)
                labels += 1
                continue
            }
            index += 1
        }
        guard labels > 0 else { return (segment, 0) }
        guard let first = words.first else { return (nil, labels) }
        var kept = segment
        if timed {
            kept.words = words
            kept.text = words.map(\.text).joined()
            kept.start = max(segment.start, first.start)
        } else {
            kept.text = words.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
        }
        return (kept, labels)
    }

    /// Whether the recorded transcript has `label`'s words (but titles) near it on `track`: for a speaker label (`:`
    /// or `-`), every one of them; for a colon-less comma list at the passage start (`isList`), any of them.
    private static func said(_ label: ArraySlice<DeepTranscribedWord>, isList: Bool, track: String,
                             spoken: SpokenWords?) -> Bool {
        guard let spoken else { return false }
        let names = DeepTranscribedLabel.labelNames(label)
        guard !names.isEmpty else { return false }
        let from = (label.map(\.start).min() ?? 0) - labelReferenceSeconds
        let to = (label.map(\.end).max() ?? 0) + labelReferenceSeconds
        let near = spoken.words(track: track, from: from, to: to)
        return isList ? names.contains(where: near.contains) : names.allSatisfy(near.contains)
    }

    /// The recorded transcript's words per track (letters and digits, lowercased), with their times, to ask which lie
    /// within an interval. A segment without timed words gives its text's words its own span; one without a track
    /// counts for every track.
    struct SpokenWords {
        private struct Word {
            var start: Double
            var end: Double
            var text: String
        }

        /// Per track, sorted by start.
        private var tracks: [String: [Word]] = [:]
        private var untracked: [Word] = []
        /// The longest word, so a search can start that far before an interval.
        private var longest = 0.0

        init(_ segments: [TranscriptSegment]) {
            var raw: [String?: [Word]] = [:]
            for segment in segments {
                let timed = WordTiming.effectiveWords(of: segment)
                let pieces: [(Double, Double, String)] = timed.isEmpty
                    ? [(segment.start, segment.end, segment.text)]
                    : timed.map { ($0.start, $0.end, $0.text) }
                for (start, end, text) in pieces where start.isFinite && end.isFinite {
                    for token in DeepTranscriptGuards.normalized(text).split(separator: " ") {
                        raw[segment.track, default: []].append(Word(start: start, end: end, text: String(token)))
                        longest = max(longest, end - start)
                    }
                }
            }
            for (track, words) in raw {
                let sorted = words.sorted { $0.start < $1.start }
                if let track { tracks[track] = sorted } else { untracked = sorted }
            }
        }

        /// The words of `track` (and untracked ones) overlapping [from, to].
        func words(track: String, from: Double, to: Double) -> Set<String> {
            var found = Set<String>()
            for words in [tracks[track] ?? [], untracked] where !words.isEmpty {
                // The first word starting at or after `from - longest` (binary search).
                var low = 0, high = words.count
                while low < high {
                    let middle = (low + high) / 2
                    if words[middle].start < from - longest { low = middle + 1 } else { high = middle }
                }
                while low < words.count, words[low].start <= to {
                    if words[low].end >= from { found.insert(words[low].text) }
                    low += 1
                }
            }
            return found
        }
    }
}
