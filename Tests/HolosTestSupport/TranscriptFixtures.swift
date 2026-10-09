import Foundation
import HolosCore

/// Transcripts with evenly timed words.
public enum TranscriptFixtures {
    public static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// A segment of `words` on `track`, one word every `every` seconds from `start`, each lasting `lasting`, with
    /// UTF-16 offsets into the space-joined text; it ends `every` after its last word starts.
    public static func segment(_ words: [String], id: String = UUID().uuidString, track: String?, start: Double,
                               every: Double = 0.5, lasting: Double = 0.4) -> TranscriptSegment {
        var text = ""
        var timed: [TimedWord] = []
        for (index, word) in words.enumerated() {
            if !text.isEmpty { text += " " }
            let wordStart = start + Double(index) * every
            timed.append(TimedWord(text: word, start: wordStart, end: wordStart + lasting,
                                   utf16Offset: text.utf16.count, utf16Length: word.utf16.count))
            text += word
        }
        return TranscriptSegment(id: id, start: start, end: start + Double(words.count) * every, text: text,
                                 words: timed, track: track)
    }

    /// `count` distinct words "<prefix>w0", "<prefix>w1", ….
    public static func numberedWords(_ prefix: String, count: Int) -> [String] {
        (0..<count).map { "\(prefix)w\($0)" }
    }

    /// A transcript of `segments` in (start, track) order.
    public static func transcript(_ segments: [TranscriptSegment], id: String = UUID().uuidString,
                                  createdAt: Date = date, locale: String = "en-CA") -> Transcript {
        let ordered = segments.sorted { ($0.start, $0.track ?? "") < ($1.start, $1.track ?? "") }
        return Transcript(id: id, createdAt: createdAt, source: "fixture", locale: locale, backend: .speech,
                          segments: ordered)
    }
}
