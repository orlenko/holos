import AVFoundation
import Foundation
import CoreMedia
import HolosCore
@testable import HolosSpeech
import Testing

@Test func volatileHypothesisIsReplacedAndFinalized() async {
    let collector = ResultCollector(onUpdate: { _ in })
    let first = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 1000),
                            duration: CMTime(seconds: 2, preferredTimescale: 1000))
    await collector.accept(text: AttributedString("helo"), range: first,
                           finalizedThrough: .zero, isFinal: false)
    await collector.accept(text: AttributedString("hello"), range: first,
                           finalizedThrough: CMTime(seconds: 3, preferredTimescale: 1000), isFinal: true)
    let segments = await collector.finalSegments()
    #expect(segments.count == 1)
    #expect(segments.first?.text == "hello")
    #expect(segments.first?.start == 1)
    #expect(segments.first?.end == 3)
    let probe = await collector.probeCounters()
    #expect(probe.nativeFinalResults == 1)
    #expect(probe.nativeFinalWords == 1)
    #expect(probe.nativeVolatileResults == 1)
    #expect(probe.acceptedFinalResults == 1)
    #expect(probe.droppedFinalResults == 0)
    #expect(probe.promotedVolatileResults == 0)
    #expect(probe.outputFinalResults == 1)
    #expect(probe.outputFinalWords == 1)
}

@Test func finalFlushPromotesUnreissuedHypothesis() async {
    let collector = ResultCollector(onUpdate: { _ in })
    let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1000))
    await collector.accept(text: AttributedString("last word"), range: range,
                           finalizedThrough: .zero, isFinal: false)
    let segments = await collector.finalSegments()
    #expect(segments.map(\.text) == ["last word"])
    let probe = await collector.probeCounters()
    #expect(probe.nativeFinalResults == 0)
    #expect(probe.promotedVolatileResults == 1)
    #expect(probe.outputFinalResults == 1)
    #expect(probe.outputFinalWords == 2)
}

@Test func timedRunsUseUTF16Offsets() {
    var first = AttributedString("👩🏽‍💻 ")
    first.audioTimeRange = CMTimeRange(start: .zero,
                                       duration: CMTime(seconds: 1, preferredTimescale: 1000))
    var second = AttributedString("hello")
    second.audioTimeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 1000),
                                        duration: CMTime(seconds: 1, preferredTimescale: 1000))
    first.append(second)
    let words = timedWords(in: first)
    #expect(words.count == 2)
    #expect(words[1].utf16Offset == "👩🏽‍💻 ".utf16.count)
    #expect(words[1].utf16Length == 5)
    #expect(words[1].start == 1)
}

@Test func punctuationWithoutDurationIsNotReportedAsAWord() {
    var word = AttributedString("Hello")
    word.audioTimeRange = CMTimeRange(start: .zero,
                                      duration: CMTime(seconds: 1, preferredTimescale: 1000))
    var punctuation = AttributedString(".")
    punctuation.audioTimeRange = CMTimeRange(start: CMTime(seconds: 1, preferredTimescale: 1000),
                                             duration: .zero)
    word.append(punctuation)
    #expect(timedWords(in: word).map(\.text) == ["Hello"])
}

@Test func failedResultConsumerUnblocksBackpressuredInput() async throws {
    let input = BoundedInput<Int>()
    try await input.send(1)
    let blocked = Task { try await input.send(2) }
    await input.fail(HolosError.incomplete("recognizer failed"))
    do {
        try await blocked.value
        Issue.record("A waiting producer must receive the recognizer failure.")
    } catch let error as HolosError {
        #expect(error.errorDescription == "recognizer failed")
    }
}

@Test func cancelledInputConsumerIsReleased() async {
    let input = BoundedInput<Int>()
    let consumer = Task {
        var iterator = input.makeAsyncIterator()
        return await iterator.next()
    }
    await Task.yield()
    consumer.cancel()
    let result = await consumer.value
    #expect(result == nil)
}

@Test func optInNativeFileAndStreamingFixture() async throws {
    guard let path = ProcessInfo.processInfo.environment["HOLOS_SPEECH_TEST_AUDIO"], !path.isEmpty else { return }
    let locale = ProcessInfo.processInfo.environment["HOLOS_SPEECH_TEST_LOCALE"] ?? "en-CA"
    let backend = SpeechBackend(rawValue: ProcessInfo.processInfo.environment["HOLOS_SPEECH_TEST_BACKEND"] ?? "speech") ?? .speech
    let url = URL(fileURLWithPath: path)
    if ProcessInfo.processInfo.environment["HOLOS_SPEECH_TEST_INSTALL_ASSETS"] == "1" {
        try await AppleSpeechEngine.installAssets(locale: locale, backend: backend)
    }
    let status = try await AppleSpeechEngine.assetStatus(locale: locale, backend: backend)
    #expect(status == "installed")
    guard status == "installed" else { return }

    let fileUpdates = SpeechUpdateRecorder()
    let file = try await AppleSpeechEngine.transcribe(file: url, locale: locale, backend: backend) {
        fileUpdates.record($0)
    }
    #expect(file.source == url.path)
    validateFinalSegments(file.segments, updates: fileUpdates.snapshot(), minimumStart: 0)
    #expect(file.text.lowercased().contains("meeting"))
    #expect(file.text.lowercased().contains("friday"))

    let audio = try AVAudioFile(forReading: url)
    let format = audio.processingFormat
    let channels = Int(format.channelCount)
    let streamUpdates = SpeechUpdateRecorder()
    let session = try await AppleSpeechSession.make(locale: locale, backend: backend) {
        streamUpdates.record($0)
    }
    let offset = 2.5
    var framesRead = 0
    while framesRead < Int(audio.length) {
        let nextCount = AVAudioFrameCount(min(2_048, Int(audio.length) - framesRead))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: nextCount))
        try audio.read(into: buffer, frameCount: nextCount)
        let count = Int(buffer.frameLength)
        if count == 0 { break }
        let data = try #require(buffer.floatChannelData)
        var samples = [Float](repeating: 0, count: count * channels)
        for index in 0..<count {
            for channel in 0..<channels {
                samples[index * channels + channel] = data[channel][index]
            }
        }
        let frame = try PCMFrame(samples: samples, sampleRate: format.sampleRate, channels: channels,
                                 startTime: offset + Double(framesRead) / format.sampleRate)
        try await session.append(frame)
        framesRead += count
    }
    #expect(framesRead > 0)
    let streamed = try await session.finish()
    validateFinalSegments(streamed, updates: streamUpdates.snapshot(), minimumStart: offset)
    let streamingText = streamed.map(\.text).joined(separator: " ").lowercased()
    #expect(streamingText.contains("meeting"))
    #expect(streamingText.contains("friday"))
}

private final class SpeechUpdateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [TranscriptUpdate] = []

    func record(_ update: TranscriptUpdate) {
        lock.lock()
        updates.append(update)
        lock.unlock()
    }

    func snapshot() -> [TranscriptUpdate] {
        lock.lock()
        defer { lock.unlock() }
        return updates
    }
}

private func validateFinalSegments(_ segments: [TranscriptSegment], updates: [TranscriptUpdate],
                                   minimumStart: Double) {
    #expect(!segments.isEmpty)
    #expect(segments.allSatisfy { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    #expect(segments.allSatisfy { $0.start >= minimumStart - 0.02 && $0.end > $0.start })
    for pair in zip(segments, segments.dropFirst()) {
        #expect(pair.0.end <= pair.1.start + 0.02)
    }
    for segment in segments {
        for word in segment.words {
            #expect(word.start >= segment.start - 0.02)
            #expect(word.end <= segment.end + 0.02)
            #expect(word.utf16Offset >= 0)
            #expect(word.utf16Offset + word.utf16Length <= segment.text.utf16.count)
        }
    }
    let finalizedIDs = updates.filter(\.isFinal).map { $0.segment.id }
    #expect(Set(finalizedIDs).count == finalizedIDs.count)
    #expect(Set(finalizedIDs) == Set(segments.map(\.id)))
}
