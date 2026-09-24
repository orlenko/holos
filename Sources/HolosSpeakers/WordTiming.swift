import Foundation
import HolosCore

/// One word of a transcript segment as speaker alignment sees it: the recognizer's timing when it has one,
/// otherwise an even spread over the segment.
public struct EffectiveWord: Sendable, Equatable {
    public let text: String
    /// Session time.
    public let start: Double
    public let end: Double
    /// UTF-16 range of the word in `TranscriptSegment.text`.
    public let utf16Offset: Int
    public let utf16Length: Int
    /// True when the time was spread evenly across an untimed segment.
    public let estimated: Bool

    public init(text: String, start: Double, end: Double, utf16Offset: Int, utf16Length: Int, estimated: Bool) {
        self.text = text; self.start = start; self.end = end
        self.utf16Offset = utf16Offset; self.utf16Length = utf16Length; self.estimated = estimated
    }
}

public enum WordTiming {
    /// `segment.words` in order when non-empty (measured). Otherwise the text split at whitespace into
    /// tokens with equal durations over [start, start + max(end − start, 0.01 × count)) (estimated).
    /// WordRef and WordSpan indices refer to this array.
    public static func effectiveWords(of segment: TranscriptSegment) -> [EffectiveWord] {
        if !segment.words.isEmpty {
            return segment.words.map {
                EffectiveWord(text: $0.text, start: $0.start, end: $0.end,
                              utf16Offset: $0.utf16Offset, utf16Length: $0.utf16Length, estimated: false)
            }
        }
        let tokens = whitespaceTokens(in: segment.text)
        guard !tokens.isEmpty else { return [] }
        let count = Double(tokens.count)
        let total = max(segment.end - segment.start, 0.01 * count)
        let step = total / count
        return tokens.enumerated().map { index, token in
            EffectiveWord(text: token.text,
                          start: segment.start + Double(index) * step,
                          end: segment.start + Double(index + 1) * step,
                          utf16Offset: token.utf16Offset, utf16Length: token.utf16Length, estimated: true)
        }
    }

    /// Maximal runs of non-whitespace characters with their UTF-16 ranges in `text`.
    private static func whitespaceTokens(in text: String) -> [(text: String, utf16Offset: Int, utf16Length: Int)] {
        var tokens: [(text: String, utf16Offset: Int, utf16Length: Int)] = []
        var current = ""
        var currentOffset = 0
        var offset = 0
        for character in text {
            let length = character.utf16.count
            if character.isWhitespace {
                if !current.isEmpty {
                    tokens.append((current, currentOffset, offset - currentOffset))
                    current = ""
                }
            } else {
                if current.isEmpty { currentOffset = offset }
                current.append(character)
            }
            offset += length
        }
        if !current.isEmpty {
            tokens.append((current, currentOffset, offset - currentOffset))
        }
        return tokens
    }
}
