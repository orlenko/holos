import Foundation
import HolosCore
import HolosSpeakers

/// Speaker labels Whisper writes into a passage that nobody said ("Jane Doe: Yes.", "Jane Doe, Ph.D.: …"), as the
/// transcripts it learned from put them (docs/meeting/deep-transcription.md §4.16). Pure.
extension DeepTranscriptGuards {
    /// The most words a label has, its colon word included ("Dr. Jane Q. Doe:").
    public static let labelMaxWords = 5
    /// How far around a label the recorded transcript's words are looked for: a label whose every word is there was
    /// said.
    public static let labelReferenceSeconds = 2.0
    /// Lowercase words a name may hold.
    static let nameParticles: Set<String> = ["al", "bin", "da", "das", "de", "del", "della", "den", "der", "di", "do",
                                             "dos", "du", "el", "la", "le", "van", "von", "y"]
    /// Titles and degrees (as letters, "Ph.D." being "ph" and "d"): not looked for in the recorded transcript.
    static let labelTitles: Set<String> = ["d", "dr", "jr", "md", "mr", "mrs", "ms", "ph", "phd", "prof", "sr"]

    /// `segment` without the speaker labels the model invented in it, and how many there were; nil when nothing else
    /// was in it. A label is 1 to `labelMaxWords` words, the last ending in ":", each starting with an uppercase letter
    /// or a digit (leading punctuation aside, as Whisper splits "Ph.D.") or a name particle, at the start of the
    /// passage or after a word ending a sentence. It stays when the recorded transcript (`spoken`) has each of its
    /// words but titles on the same track within `labelReferenceSeconds`: it was said ("Question: …"). Without a
    /// recorded transcript the shape alone decides. A segment without word timings is looked at by its text.
    static func withoutLabels(_ segment: DeepHeardSegment, spoken: SpokenWords?)
        -> (segment: DeepHeardSegment?, labels: Int) {
        let timed = !segment.words.isEmpty
        var words = timed ? segment.words : segment.text.split(whereSeparator: \.isWhitespace).map {
            DeepTranscribedWord(text: " " + $0, start: segment.start, end: segment.end)
        }
        var labels = 0
        var index = 0
        while index < words.count {
            let starts = index == 0 || endsSentence(words[index - 1].text)
            if starts, let end = labelEnd(words, from: index),
               !said(words[index...end], track: segment.track, spoken: spoken) {
                words.removeSubrange(index...end)
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

    /// The index of a label's colon word when one starts at `start`.
    private static func labelEnd(_ words: [DeepTranscribedWord], from start: Int) -> Int? {
        for index in start..<min(words.count, start + labelMaxWords) {
            let text = words[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isLabelWord(text) else { return nil }
            if text.hasSuffix(":") { return index }
        }
        return nil
    }

    private static func isLabelWord(_ text: String) -> Bool {
        let core = text.drop { $0.isPunctuation || $0.isSymbol }
        guard let first = core.first else { return false }
        if first.isUppercase || first.isNumber { return true }
        return nameParticles.contains(core.trimmingCharacters(in: .punctuationCharacters))
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return last == "." || last == "?" || last == "!"
    }

    /// Whether the recorded transcript has every word of `label` but titles near it on `track`.
    private static func said(_ label: ArraySlice<DeepTranscribedWord>, track: String, spoken: SpokenWords?) -> Bool {
        guard let spoken else { return false }
        let names = label.flatMap { normalized($0.text).split(separator: " ").map(String.init) }
            .filter { !labelTitles.contains($0) }
        guard !names.isEmpty else { return false }
        let from = (label.map(\.start).min() ?? 0) - labelReferenceSeconds
        let to = (label.map(\.end).max() ?? 0) + labelReferenceSeconds
        let near = spoken.words(track: track, from: from, to: to)
        return names.allSatisfy(near.contains)
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
