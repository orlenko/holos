import CoreML
import Foundation
@preconcurrency import WhisperKit

/// WhisperKit's `SegmentSeeker` with word timestamps that stay right when a prompt is given, and punctuation merged
/// per segment without dropping tokens across sub-segment boundaries (docs/meeting/deep-transcription.md §4.16).
///
/// WhisperKit 1.1.0's decoder stores each position's alignment weights at its absolute index in the decoder input,
/// which starts with `<|startofprev|>` and the prompt's tokens, while the segments' tokens (and so the rows
/// `addWordTimestamps` reads) start at `<|startoftranscript|>`. With a prompt every word was aligned with the weights of
/// a token `prompt + 1` places earlier: on invented speech after 3 s of silence the first words were put in the
/// silence and the rest seconds early. This seeker moves the weights up by that many rows before WhisperKit aligns the
/// words, keeping the array's row stride (Core ML pads 1500 frames to 1504), so the rows WhisperKit reads are those it
/// reads without a prompt; without a prompt it changes nothing.
///
/// WhisperKit's own punctuation pass also runs on the window's flat word list before `updateSegmentsWithWordTimings`
/// partitions it back into sub-segments by token count, and deletes any unmerged punctuation token (such as "-" after
/// a name before a spaced word), shifting later sub-segments' words into earlier ones. Merged per segment afterwards
/// instead, no token is dropped and every sub-segment keeps its own words.
final class PromptAlignedSegmentSeeker: SegmentSeeking {
    private let base = SegmentSeeker()

    func findSeekPointAndSegments(decodingResult: DecodingResult, options: DecodingOptions, allSegmentsCount: Int,
                                  currentSeek seek: Int, segmentSize: Int, sampleRate: Int, timeToken: Int,
                                  specialToken: Int, tokenizer: WhisperTokenizer) -> (Int, [TranscriptionSegment]?) {
        base.findSeekPointAndSegments(decodingResult: decodingResult, options: options,
                                      allSegmentsCount: allSegmentsCount, currentSeek: seek, segmentSize: segmentSize,
                                      sampleRate: sampleRate, timeToken: timeToken, specialToken: specialToken,
                                      tokenizer: tokenizer)
    }

    func addWordTimestamps(segments: [TranscriptionSegment], alignmentWeights: MLMultiArray,
                           tokenizer: WhisperTokenizer, seek: Int, segmentSize: Int, prependPunctuations: String,
                           appendPunctuations: String, lastSpeechTimestamp: Float, options: DecodingOptions,
                           timings: TranscriptionTimings) throws -> [TranscriptionSegment]? {
        let offset = Self.promptRows(options.promptTokens, specialTokenBegin: tokenizer.specialTokens.specialTokenBegin)
        let weights = offset == 0 ? alignmentWeights : try Self.shifted(alignmentWeights, by: offset)
        guard let timed = try base.addWordTimestamps(segments: segments, alignmentWeights: weights,
                                                     tokenizer: tokenizer, seek: seek, segmentSize: segmentSize,
                                                     prependPunctuations: "", appendPunctuations: "",
                                                     lastSpeechTimestamp: lastSpeechTimestamp, options: options,
                                                     timings: timings) else { return nil }
        return timed.map { segment in
            var copy = segment
            if let words = copy.words {
                copy.words = Self.mergePunctuations(words, prepended: prependPunctuations, appended: appendPunctuations)
            }
            return copy
        }
    }

    /// Punctuation words in `words` (one segment's timed words) joined to their neighbours without dropping a token
    /// that stands alone: a `prepended` mark with a leading space (or at index 0) joins an unspaced word after it; an
    /// `appended` mark, or an unspaced `prepended` mark (such as "-" after a name before a spaced word), joins the
    /// word before it.
    static func mergePunctuations(_ words: [WordTiming],
                                  prepended: String = Constants.defaultPrependPunctuations,
                                  appended: String = Constants.defaultAppendPunctuations) -> [WordTiming] {
        guard !words.isEmpty else { return [] }
        func isMark(_ text: String, in set: String) -> Bool {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.count == 1 && set.contains(trimmed)
        }
        var afterPrepend: [WordTiming] = []
        var index = 0
        while index < words.count {
            let current = words[index]
            if index + 1 < words.count,
               index == 0 || current.word.first?.isWhitespace == true,
               isMark(current.word, in: prepended),
               words[index + 1].word.first?.isWhitespace != true {
                var next = words[index + 1]
                next.word = current.word + next.word
                next.tokens = current.tokens + next.tokens
                next.start = min(current.start, next.start)
                next.end = max(current.end, next.end)
                afterPrepend.append(next)
                index += 2
            } else {
                afterPrepend.append(current)
                index += 1
            }
        }
        var out: [WordTiming] = []
        for current in afterPrepend {
            let trimmed = current.word.trimmingCharacters(in: .whitespaces)
            let canAppend = isMark(current.word, in: appended)
                || (current.word.first?.isWhitespace != true && isMark(current.word, in: prepended))
            if canAppend, var previous = out.last, !previous.word.hasSuffix(" ") {
                previous.word += trimmed
                previous.tokens += current.tokens
                previous.end = max(previous.end, current.end)
                out[out.count - 1] = previous
            } else {
                out.append(current)
            }
        }
        return out
    }

    /// The decoder positions before `<|startoftranscript|>` that a prompt adds, as WhisperKit's `TextDecoder` builds
    /// them: `<|startofprev|>` and the prompt's last 223 tokens below the special tokens; 0 without any.
    static func promptRows(_ promptTokens: [Int]?, specialTokenBegin: Int) -> Int {
        guard let promptTokens else { return 0 }
        let maximum = Constants.maxTokenContext / 2 - 1
        let kept = promptTokens.suffix(maximum).filter { $0 < specialTokenBegin }.count
        return kept == 0 ? 0 : kept + 1
    }

    /// `weights` (positions × encoder frames) with row `i + offset` moved to row `i` and the last `offset` rows zero,
    /// in an array with the same shape, type and strides (so a reader that assumes the original's layout reads it the
    /// same way).
    static func shifted(_ weights: MLMultiArray, by offset: Int) throws -> MLMultiArray {
        guard weights.shape.count == 2, weights.strides.count == 2, weights.strides[1].intValue == 1 else {
            return weights
        }
        let rows = weights.shape[0].intValue
        let columns = weights.shape[1].intValue
        let stride = weights.strides[0].intValue
        let element: Int
        switch weights.dataType {
        case .float16: element = 2
        case .float32: element = 4
        case .double: element = 8
        default: return weights
        }
        let bytes = rows * stride * element
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(1, bytes), alignment: 64)
        memset(buffer, 0, bytes)
        for row in 0..<max(0, rows - offset) {
            memcpy(buffer.advanced(by: row * stride * element),
                   weights.dataPointer.advanced(by: (row + offset) * stride * element), columns * element)
        }
        return try MLMultiArray(dataPointer: buffer, shape: weights.shape, dataType: weights.dataType,
                                strides: weights.strides, deallocator: { $0.deallocate() })
    }
}
