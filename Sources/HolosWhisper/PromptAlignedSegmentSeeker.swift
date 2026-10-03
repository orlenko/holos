import CoreML
import Foundation
@preconcurrency import WhisperKit

/// WhisperKit's `SegmentSeeker` with word timestamps that stay right when a prompt is given (docs/meeting-design.md
/// §4.16).
///
/// WhisperKit 1.1.0's decoder stores each position's alignment weights at its absolute index in the decoder input,
/// which starts with `<|startofprev|>` and the prompt's tokens, while the segments' tokens (and so the rows
/// `addWordTimestamps` reads) start at `<|startoftranscript|>`. With a prompt every word was aligned with the weights of
/// a token `prompt + 1` places earlier: on invented speech after 3 s of silence the first words were put in the
/// silence and the rest seconds early. This seeker moves the weights up by that many rows before WhisperKit aligns the
/// words, keeping the array's row stride (Core ML pads 1500 frames to 1504), so the rows WhisperKit reads are those it
/// reads without a prompt; without a prompt it changes nothing.
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
        return try base.addWordTimestamps(segments: segments, alignmentWeights: weights, tokenizer: tokenizer,
                                          seek: seek, segmentSize: segmentSize,
                                          prependPunctuations: prependPunctuations,
                                          appendPunctuations: appendPunctuations,
                                          lastSpeechTimestamp: lastSpeechTimestamp, options: options,
                                          timings: timings)
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
