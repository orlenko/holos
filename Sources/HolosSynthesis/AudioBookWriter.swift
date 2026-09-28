import AVFoundation
import CoreMedia
import Foundation
import HolosCore

/// The one audio format for readings: speech-tuned AAC in `.m4a`, which iPhone, Android, Windows,
/// and browsers all play. About 14 MB per hour. macOS has no MP3 encoder, so MP3 is not offered.
public enum ReadingAudioFormat {
    public static let fileExtension = "m4a"
    public static let sampleRate: Double = 22_050
    public static let bitRate = 32_000
    public static let channels = 1
    /// Silence added between rendered parts, and before a part that starts a chapter.
    public static let partGap: Double = 0.5
    public static let chapterGap: Double = 1.0
}

public struct AudioBookPart: Sendable, Equatable {
    /// A PCM file (CAF or WAV) rendered by `NativeSpeechRenderer`.
    public let url: URL
    public let silenceBefore: Double
    /// Starts a chapter with this title.
    public let chapter: String?

    public init(url: URL, silenceBefore: Double = 0, chapter: String? = nil) {
        self.url = url
        self.silenceBefore = silenceBefore
        self.chapter = chapter
    }
}

public struct AudioBookMetadata: Sendable, Equatable {
    public var title: String?
    public var author: String?
    /// BCP 47 language of the text, when known.
    public var language: String?
    public var comment: String

    public init(title: String?, author: String? = nil, language: String? = nil,
                comment: String = "Read aloud with Voice is Local") {
        self.title = title
        self.author = author
        self.language = language
        self.comment = comment
    }

    /// `title` as the file stores it (trimmed and shortened, see `AudioBookWriter.fileText`), or
    /// nil when no readable text is left: nothing but spaces, control, or format characters.
    public static func usableTitle(_ title: String?) -> String? {
        guard let text = AudioBookWriter.fileText(title),
              text.unicodeScalars.contains(where: { scalar in
                  !scalar.properties.isWhitespace
                      && ![.control, .format].contains(scalar.properties.generalCategory)
              }) else { return nil }
        return text
    }

    /// `language` as a tag the file can carry: a known ISO 639 language with an optional script
    /// and region ("en", "zh-Hant-TW", "es-419"), or nil. AVFoundation raises an uncatchable
    /// exception for a tag it rejects (such as "english" from `<html lang>`), so nothing else is
    /// ever passed to it. Variants and extensions are dropped.
    public static func languageTag(_ language: String?) -> String? {
        guard let language else { return nil }
        let subtags = language.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false)
            .map(String.init)
        func letters(_ text: String, _ counts: ClosedRange<Int>) -> Bool {
            counts.contains(text.count) && text.allSatisfy { $0.isASCII && $0.isLetter }
        }
        guard let first = subtags.first, letters(first, 2...3) else { return nil }
        let code = first.lowercased()
        guard code != "und", Locale.LanguageCode(code).isISOLanguage else { return nil }
        var tag = code
        var rest = subtags.dropFirst()
        if let script = rest.first, letters(script, 4...4) {
            tag += "-" + script.prefix(1).uppercased() + script.dropFirst().lowercased()
            rest = rest.dropFirst()
        }
        if let region = rest.first,
           letters(region, 2...2) || (region.count == 3 && region.allSatisfy { $0.isASCII && $0.isNumber }) {
            tag += "-" + region.uppercased()
        }
        return tag
    }
}

public struct AudioBookChapter: Sendable, Equatable, Codable {
    public let title: String
    public let start: Double

    public init(title: String, start: Double) {
        self.title = title
        self.start = start
    }
}

public struct AudioBookSummary: Sendable, Equatable {
    public let url: URL
    public let duration: Double
    /// Empty when the book has fewer than two chapters: a single chapter adds nothing.
    public let chapters: [AudioBookChapter]

    public init(url: URL, duration: Double, chapters: [AudioBookChapter]) {
        self.url = url
        self.duration = duration
        self.chapters = chapters
    }
}

/// The chapter track a book gets, from each part's chapter title and where the part starts. The
/// one set of rules `AudioBookWriter` encodes and `voiceislocal read --print-text` shows:
/// - a part's title (trimmed, and shortened as the file stores it) starts a chapter; an empty one
///   does not;
/// - a chapter that would start where the previous one does, or earlier, is dropped;
/// - when the first chapter starts after the beginning, a chapter named after the book (or
///   "Beginning") is added at the start, so the opening is reachable too;
/// - fewer than two chapters make no chapter track.
public enum AudioBookChapterPlan {
    public static func marks<Position: Comparable & AdditiveArithmetic>(
        _ parts: [(chapter: String?, position: Position)], bookTitle: String?
    ) -> [(title: String, position: Position)] {
        var marks: [(title: String, position: Position)] = []
        for part in parts {
            guard let title = AudioBookWriter.fileText(part.chapter) else { continue }
            if let last = marks.last, last.position >= part.position { continue }
            marks.append((title, part.position))
        }
        if let first = marks.first, first.position > .zero {
            marks.insert((AudioBookWriter.fileText(bookTitle) ?? "Beginning", .zero), at: 0)
        }
        return marks.count < 2 ? [] : marks
    }

    /// The chapter titles for parts in reading order, the first starting at the beginning and
    /// each later one after the one before (every part after the first has silence before it).
    public static func titles(_ chapters: [String?], bookTitle: String?) -> [String] {
        marks(chapters.enumerated().map { ($0.element, $0.offset) }, bookTitle: bookTitle).map(\.title)
    }
}

/// Joins rendered PCM parts into one AAC `.m4a` (a single encoding pass) with title, author, and
/// encoder metadata and, when there are at least two, a chapter track (a QuickTime/MPEG-4 text
/// track referenced from the audio track, which Apple Books, Podcasts, QuickTime, VLC, and
/// ffmpeg read).
public enum AudioBookWriter {
    private static let framesPerBuffer: AVAudioFrameCount = 8_192
    /// The longest silence a part may ask for, in seconds.
    static let maximumSilence: Double = 3_600
    /// The highest part sample rate accepted (far below the Int32 CMTime timescale limit).
    static let maximumSampleRate: Double = 768_000
    /// The most channels a part may have.
    static let maximumChannels: AVAudioChannelCount = 64

    public static func write(parts: [AudioBookPart], metadata: AudioBookMetadata,
                             to output: URL) async throws -> AudioBookSummary {
        try await write(parts: parts, metadata: metadata, to: output, faults: Faults())
    }

    static func write(parts: [AudioBookPart], metadata: AudioBookMetadata, to output: URL,
                      faults: Faults) async throws -> AudioBookSummary {
        guard !parts.isEmpty else { throw HolosError.invalidInput("A reading needs at least one audio part.") }
        guard output.isFileURL else { throw HolosError.invalidInput("Reading output must be a file URL.") }
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw HolosError.invalidInput("Reading output already exists: \(output.path)")
        }
        // Files are opened one at a time (here and while encoding): a long book has hundreds.
        var lengths: [Int64] = []
        var sourceFormat: AVAudioFormat?
        for part in parts {
            guard part.silenceBefore.isFinite, part.silenceBefore >= 0, part.silenceBefore <= maximumSilence else {
                throw HolosError.invalidInput("Silence before a part must be between 0 and \(Int(maximumSilence)) seconds.")
            }
            let file = try openPart(part.url)
            guard sourceFormat == nil || file.processingFormat == sourceFormat else {
                throw HolosError.io("Reading parts do not share one audio format.")
            }
            sourceFormat = file.processingFormat
            lengths.append(file.length)
        }
        // The rate is a CMTime timescale (Int32) once rounded, and the channel count sizes buffers.
        guard let format = sourceFormat, format.sampleRate.isFinite, format.sampleRate >= 1,
              format.sampleRate <= maximumSampleRate, format.channelCount > 0,
              format.channelCount <= maximumChannels else {
            throw HolosError.io("Reading parts have no usable audio format.")
        }
        let rate = format.sampleRate

        // Timeline in source frames: where each part starts and where each chapter starts. Every
        // term is bounded (silence by `maximumSilence`, rate by `maximumSampleRate`), and the sum
        // is checked, so no length or count read from the part files can trap.
        var starts: [Int64] = []
        var silences: [Int64] = []
        var position: Int64 = 0
        func advance(_ frames: Int64) throws {
            let (sum, overflow) = position.addingReportingOverflow(frames)
            guard !overflow, frames >= 0 else { throw HolosError.io("Reading parts are too long to join.") }
            position = sum
        }
        for (part, length) in zip(parts, lengths) {
            let silence = Int64((part.silenceBefore * rate).rounded())
            silences.append(silence)
            try advance(silence)
            starts.append(position)
            try advance(length)
        }
        let total = position
        // A chapter begins at the silence before its part, so skipping to it is not abrupt.
        let chapterMarks = AudioBookChapterPlan.marks(
            parts.indices.map { (parts[$0].chapter, $0 == 0 ? 0 : starts[$0] - silences[$0]) },
            bookTitle: metadata.title
        ).map { (title: $0.title, frame: $0.position) }

        let language = AudioBookMetadata.languageTag(metadata.language)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: ReadingAudioFormat.sampleRate,
            AVNumberOfChannelsKey: ReadingAudioFormat.channels,
            AVEncoderBitRateKey: ReadingAudioFormat.bitRate,
            AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_LongTermAverage,
        ], sourceFormatHint: format.formatDescription)
        let audio = writer.inputReceiver(for: audioInput)
        var text: AVAssetWriterInput.SampleBufferReceiver?
        var textFormat: CMFormatDescription?
        if !chapterMarks.isEmpty {
            let description = try chapterTextFormat()
            let textInput = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: description)
            textInput.marksOutputTrackAsEnabled = false
            if let language { textInput.extendedLanguageTag = language }
            text = writer.inputReceiver(for: textInput)
            audioInput.addTrackAssociation(withTrackOf: textInput,
                                           type: AVAssetTrack.AssociationType.chapterList.rawValue)
            textFormat = description
        }
        if let language { audioInput.extendedLanguageTag = language }
        writer.metadata = metadataItems(metadata)

        var finished = false
        defer {
            if !finished {
                if writer.status == .writing { writer.cancelWriting() }
                try? FileManager.default.removeItem(at: output)
            }
        }
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        // The writer interleaves the two tracks and holds back whichever input runs ahead, so
        // chapters and audio are appended concurrently: appending either one alone can wait
        // forever for the other. They fail together: each side finishes its own input however it
        // ends, which releases an append the other side is waiting in (neither task cancellation
        // nor `cancelWriting` does), and the first error cancels the other side, which stops at
        // its next sample. Only then, with neither side appending, is the writer cancelled (by
        // the `defer` above).
        let chapterSamples = chapterMarks.enumerated().map { index, mark in
            ChapterMark(title: mark.title, start: mark.frame,
                        end: index + 1 < chapterMarks.count ? chapterMarks[index + 1].frame : total)
        }
        // Each receiver is used by its own task alone, and never again here.
        nonisolated(unsafe) let chapterReceiver = text
        nonisolated(unsafe) let audioReceiver = audio
        let chapterFormat = textFormat
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await appendChapters(chapterSamples, to: chapterReceiver, format: chapterFormat, rate: rate,
                                         fault: faults.chapter)
            }
            group.addTask { [starts, lengths] in
                try await appendAudio(parts: parts, starts: starts, lengths: lengths, format: format, to: audioReceiver,
                                      fault: faults.audio)
            }
            // `next()` rethrows the first error at once; leaving the group then cancels the other
            // side and waits for it.
            while try await group.next() != nil {}
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw HolosError.io("Could not write the reading audio: \(writer.error?.localizedDescription ?? "unknown error")")
        }
        finished = true
        return AudioBookSummary(url: output, duration: Double(total) / rate,
                                chapters: chapterMarks.map { AudioBookChapter(title: $0.title, start: Double($0.frame) / rate) })
    }

    private struct ChapterMark: Sendable {
        let title: String
        let start: Int64
        let end: Int64
    }

    /// Errors a test makes the writer meet: before the chapter at an index, or before the audio
    /// buffer at a frame, is appended.
    struct Faults: Sendable {
        var chapter: (@Sendable (Int) async throws -> Void)?
        var audio: (@Sendable (Int64) async throws -> Void)?
    }

    private static func appendChapters(_ marks: [ChapterMark],
                                       to receiver: sending AVAssetWriterInput.SampleBufferReceiver?,
                                       format: CMFormatDescription?, rate: Double,
                                       fault: (@Sendable (Int) async throws -> Void)?) async throws {
        guard let receiver, let format else { return }
        // Finished on failure too, so the audio side is never left waiting for chapters.
        defer { receiver.finish() }
        for (index, mark) in marks.enumerated() {
            try Task.checkCancellation()
            try await fault?(index)
            let sample = try chapterSample(mark.title, format: format, start: time(mark.start, rate),
                                           duration: time(max(1, mark.end - mark.start), rate))
            try await receiver.append(CMReadySampleBuffer(unsafeBuffer: sample))
        }
    }

    private static func openPart(_ url: URL) throws -> AVAudioFile {
        try AVAudioFile(forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    }

    private static func appendAudio(parts: [AudioBookPart], starts: [Int64], lengths: [Int64], format: AVAudioFormat,
                                    to receiver: sending AVAssetWriterInput.SampleBufferReceiver,
                                    fault: (@Sendable (Int64) async throws -> Void)?) async throws {
        // Finished on failure too, so the chapter side is never left waiting for audio.
        defer { receiver.finish() }
        let rate = format.sampleRate
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerBuffer) else {
            throw HolosError.io("Could not allocate reading audio buffers.")
        }
        silence.frameLength = framesPerBuffer
        if let channel = silence.int16ChannelData?[0] {
            channel.update(repeating: 0, count: Int(framesPerBuffer) * Int(format.channelCount))
        }
        var frame: Int64 = 0
        for (index, part) in parts.enumerated() {
            let file = try openPart(part.url)
            guard file.processingFormat == format, file.length == lengths[index] else {
                throw HolosError.io("Reading part changed while it was being joined: \(part.url.lastPathComponent)")
            }
            while frame < starts[index] {
                try Task.checkCancellation()
                let length = min(Int64(framesPerBuffer), starts[index] - frame)
                silence.frameLength = AVAudioFrameCount(length)
                try await fault?(frame)
                try await receiver.append(CMReadySampleBuffer(unsafeBuffer: try sampleBuffer(silence, at: frame, rate: rate)))
                frame += length
            }
            file.framePosition = 0
            while file.framePosition < file.length {
                try Task.checkCancellation()
                let length = min(Int64(framesPerBuffer), file.length - file.framePosition)
                try file.read(into: buffer, frameCount: AVAudioFrameCount(length))
                guard buffer.frameLength > 0 else {
                    throw HolosError.incomplete("Reading part ended before its declared length: \(parts[index].url.lastPathComponent)")
                }
                try await fault?(frame)
                try await receiver.append(CMReadySampleBuffer(unsafeBuffer: try sampleBuffer(buffer, at: frame, rate: rate)))
                frame += Int64(buffer.frameLength)
            }
        }
    }

    private static func time(_ frames: Int64, _ rate: Double) -> CMTime {
        CMTime(value: frames, timescale: CMTimeScale(rate.rounded()))
    }

    /// The most UTF-8 bytes any string written into the file may take. A tx3g chapter sample
    /// stores its text length in a 16-bit field; iTunes metadata atoms have 32-bit sizes, but
    /// title, artist, and comment are held to the same limit so no field is unbounded.
    static let maximumTextBytes = Int(UInt16.max)

    /// `text` trimmed and, when longer than `maximumTextBytes` in UTF-8, shortened on a character
    /// boundary (never inside a multibyte scalar or an emoji sequence); nil when empty.
    static func fileText(_ text: String?, maximumBytes: Int = maximumTextBytes) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        guard text.utf8.count > maximumBytes else { return text }
        var bytes = 0
        var end = text.startIndex
        for character in text {
            let size = character.utf8.count
            guard bytes + size <= maximumBytes else { break }
            bytes += size
            end = text.index(after: end)
        }
        let shortened = text[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return shortened.isEmpty ? nil : shortened
    }

    private static func metadataItems(_ metadata: AudioBookMetadata) -> [AVMetadataItem] {
        func item(_ identifier: AVMetadataIdentifier, _ value: String?) -> AVMetadataItem? {
            guard let value = fileText(value) else { return nil }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            return item
        }
        return [
            item(.iTunesMetadataSongName, metadata.title),
            item(.iTunesMetadataArtist, metadata.author),
            item(.iTunesMetadataEncodingTool, "Voice is Local"),
            item(.iTunesMetadataUserComment, metadata.comment),
        ].compactMap { $0 }
    }

    /// Copies interleaved 16-bit PCM into a new sample buffer that shares no memory with `buffer`.
    private static func sampleBuffer(_ buffer: AVAudioPCMBuffer, at frame: Int64,
                                     rate: Double) throws -> sending CMSampleBuffer {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard let samples = buffer.int16ChannelData?[0] else {
            throw HolosError.io("Reading audio is not interleaved 16-bit PCM.")
        }
        let bytes = Array(UnsafeRawBufferPointer(start: samples, count: frames * channels * MemoryLayout<Int16>.size))
        let block = try blockBuffer(bytes)
        var sample: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: buffer.format.formatDescription,
            sampleCount: frames, presentationTimeStamp: time(frame, rate), packetDescriptions: nil,
            sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw HolosError.io("Could not create an audio sample buffer (\(status)).") }
        return sample
    }

    private static func blockBuffer(_ bytes: [UInt8]) throws -> CMBlockBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count,
                                                        blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                        dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                        blockBufferOut: &block)
        guard status == noErr, let block else { throw HolosError.io("Could not allocate a sample buffer (\(status)).") }
        status = CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: block, offsetIntoDestination: 0,
                                               dataLength: bytes.count)
        guard status == noErr else { throw HolosError.io("Could not fill a sample buffer (\(status)).") }
        return block
    }

    /// A 3GPP timed-text (tx3g) description: the chapter format of `.m4a` audiobooks.
    private static func chapterTextFormat() throws -> CMFormatDescription {
        let color: (Int) -> [CFString: Int] = { value in [
            kCMTextFormatDescriptionColor_Red: value, kCMTextFormatDescriptionColor_Green: value,
            kCMTextFormatDescriptionColor_Blue: value, kCMTextFormatDescriptionColor_Alpha: 255,
        ] }
        let extensions: [CFString: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor: color(0),
            kCMTextFormatDescriptionExtension_DefaultTextBox: [
                kCMTextFormatDescriptionRect_Top: 0, kCMTextFormatDescriptionRect_Left: 0,
                kCMTextFormatDescriptionRect_Bottom: 0, kCMTextFormatDescriptionRect_Right: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle: [
                kCMTextFormatDescriptionStyle_StartChar: 0, kCMTextFormatDescriptionStyle_EndChar: 0,
                kCMTextFormatDescriptionStyle_Font: 1, kCMTextFormatDescriptionStyle_FontFace: 0,
                kCMTextFormatDescriptionStyle_ForegroundColor: color(255),
                kCMTextFormatDescriptionStyle_FontSize: 12,
            ] as [CFString: Any],
            kCMTextFormatDescriptionExtension_HorizontalJustification: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification: 0,
            kCMTextFormatDescriptionExtension_FontTable: ["1": "Sans-Serif"],
        ]
        var description: CMFormatDescription?
        let status = CMFormatDescriptionCreate(allocator: nil, mediaType: kCMMediaType_Text,
                                               mediaSubType: kCMTextFormatType_3GText,
                                               extensions: extensions as CFDictionary,
                                               formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw HolosError.io("Could not describe the chapter track (\(status)).")
        }
        return description
    }

    /// One tx3g sample: a big-endian UInt16 byte count followed by the UTF-8 title, which
    /// `fileText` has already fitted to that count on a character boundary.
    private static func chapterSample(_ title: String, format: CMFormatDescription,
                                      start: CMTime, duration: CMTime) throws -> sending CMSampleBuffer {
        let utf8 = Array(title.utf8)
        guard utf8.count <= maximumTextBytes else { throw HolosError.invalidInput("A chapter title is too long.") }
        let bytes = [UInt8(utf8.count >> 8), UInt8(utf8.count & 0xff)] + utf8
        let block = try blockBuffer(bytes)
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid)
        var size = bytes.count
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil,
                                      refcon: nil, formatDescription: format, sampleCount: 1,
                                      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw HolosError.io("Could not create a chapter sample (\(status)).") }
        return sample
    }
}
