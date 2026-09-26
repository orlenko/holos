import AVFoundation
import CoreMedia
import Foundation
import HolosCore
import Speech

public enum AppleSpeechEngine {
    /// Exact readiness for the configured module, unlike the locale inventory.
    public static func assetStatus(locale: String, backend: SpeechBackend) async throws -> String {
        let module = try await makeModule(locale: locale, backend: backend)
        switch await AssetInventory.status(forModules: [module.module]) {
        case .unsupported: return "unsupported"
        case .downloading: return "downloading"
        case .supported: return "supported"
        case .installed: return "installed"
        @unknown default: return "unknown"
        }
    }

    public static func capabilities(backend: SpeechBackend) async -> SpeechCapabilities {
        let supported: [Locale]
        let installed: [Locale]
        let available: Bool
        switch backend {
        case .speech:
            supported = await SpeechTranscriber.supportedLocales
            installed = await SpeechTranscriber.installedLocales
            available = SpeechTranscriber.isAvailable
        case .dictation:
            supported = await DictationTranscriber.supportedLocales
            installed = await DictationTranscriber.installedLocales
            available = !supported.isEmpty
        }
        return SpeechCapabilities(backend: backend, isAvailable: available,
                                  supportedLocales: supported.map(\.identifier).sorted(),
                                  installedLocales: installed.map(\.identifier).sorted())
    }

    public static func installAssets(locale: String, backend: SpeechBackend) async throws {
        let module = try await makeModule(locale: locale, backend: backend)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module.module]) {
            try await request.downloadAndInstall()
        }
        guard await AssetInventory.status(forModules: [module.module]) == .installed else {
            throw HolosError.unavailable("Speech assets for \(locale) are not installed yet.")
        }
    }

    public static func transcribe(file: URL, locale: String, backend: SpeechBackend,
                                  onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) async throws -> Transcript {
        guard file.isFileURL else { throw HolosError.invalidInput("Transcription needs a local audio file.") }
        let module = try await installedModule(locale: locale, backend: backend)
        let audioFile = try AVAudioFile(forReading: file)
        let collector = ResultCollector(onUpdate: onUpdate)
        let analyzer = SpeechAnalyzer(modules: [module.module])
        let resultTask = consume(module: module, into: collector, analyzer: analyzer)
        do {
            try Task.checkCancellation()
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await resultTask.value
            let segments = await collector.finalSegments()
            if ProcessInfo.processInfo.environment["HOLOS_SPEECH_PROBE"] == "1" {
                let counters = await collector.probeCounters()
                // Diagnostic metadata only: never emit recognition text or input paths.
                if let encoded = try? JSONEncoder().encode(counters) {
                    try? FileHandle.standardError.write(contentsOf: encoded + Data([10]))
                }
            }
            return Transcript(source: file.path, locale: locale, backend: backend, segments: segments)
        } catch {
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            _ = try? await resultTask.value
            throw error
        }
    }

    /// `accurate` (speech backend only): final results only, without `fastResults`, for saved audio transcribed after
    /// a meeting, where nothing waits for the words (docs/meeting-design.md §4.14). Otherwise the progressive preset,
    /// whose fast, volatile results a live transcript needs.
    fileprivate static func makeModule(locale: String, backend: SpeechBackend,
                                       accurate: Bool = false) async throws -> Module {
        guard !locale.isEmpty else { throw HolosError.invalidInput("Locale must not be empty.") }
        let requested = Locale(identifier: locale)
        switch backend {
        case .speech:
            guard SpeechTranscriber.isAvailable,
                  let supported = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                throw HolosError.unavailable("Speech transcription does not support \(locale).")
            }
            if accurate {
                return .speech(SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                                 attributeOptions: [.audioTimeRange, .transcriptionConfidence]))
            }
            let preset = SpeechTranscriber.Preset.timeIndexedProgressiveTranscription
            return .speech(SpeechTranscriber(
                locale: supported, transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: preset.reportingOptions,
                attributeOptions: preset.attributeOptions.union([.transcriptionConfidence])))
        case .dictation:
            guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: requested) else {
                throw HolosError.unavailable("Dictation transcription does not support \(locale).")
            }
            let preset = DictationTranscriber.Preset.timeIndexedLongDictation
            return .dictation(DictationTranscriber(
                locale: supported, contentHints: preset.contentHints,
                transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: preset.reportingOptions.union([.volatileResults]),
                attributeOptions: preset.attributeOptions.union([.transcriptionConfidence])))
        }
    }

    fileprivate static func installedModule(locale: String, backend: SpeechBackend,
                                            accurate: Bool = false) async throws -> Module {
        let module = try await makeModule(locale: locale, backend: backend, accurate: accurate)
        guard await AssetInventory.status(forModules: [module.module]) == .installed else {
            throw HolosError.unavailable("Speech assets for \(locale) are missing. Run setup first.")
        }
        return module
    }
}

public actor AppleSpeechSession {
    private let analyzer: SpeechAnalyzer
    private let converter: AnalyzerInputConverter
    private let input: BoundedInput<AnalyzerInput>
    private let collector: ResultCollector
    private let resultTask: Task<Void, Error>
    private var ended = false
    private var cancelled = false
    private var appending = false
    private var appendWaiters: [CheckedContinuation<Void, Never>] = []
    private var lastEnd: Double = 0

    private init(analyzer: SpeechAnalyzer, converter: AnalyzerInputConverter, input: BoundedInput<AnalyzerInput>,
                 collector: ResultCollector, resultTask: Task<Void, Error>) {
        self.analyzer = analyzer
        self.converter = converter
        self.input = input
        self.collector = collector
        self.resultTask = resultTask
    }

    /// `accurate`: final results only, without the progressive preset's fast results (speech backend), for saved
    /// audio transcribed after a meeting (docs/meeting-design.md §4.14).
    public static func make(locale: String, backend: SpeechBackend, contextualStrings: [String] = [],
                            accurate: Bool = false,
                            onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) async throws -> AppleSpeechSession {
        let module = try await AppleSpeechEngine.installedModule(locale: locale, backend: backend, accurate: accurate)
        let converter = try await AnalyzerInputConverter.converter(compatibleWith: [module.module])
        let input = BoundedInput<AnalyzerInput>()
        let collector = ResultCollector(onUpdate: onUpdate)
        let analyzer = SpeechAnalyzer(modules: [module.module])
        let resultTask = consume(module: module, into: collector, analyzer: analyzer, input: input)
        do {
            if !contextualStrings.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = contextualStrings
                // Vocabulary biasing is best effort; corrections are still applied to the text afterwards.
                try? await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: input)
            return AppleSpeechSession(analyzer: analyzer, converter: converter, input: input,
                                      collector: collector, resultTask: resultTask)
        } catch {
            await analyzer.cancelAndFinishNow()
            resultTask.cancel()
            throw error
        }
    }

    public func append(_ frame: PCMFrame) async throws {
        guard !ended else { throw HolosError.invalidInput("The speech session has ended.") }
        guard !appending else { throw HolosError.invalidInput("Only one task may append speech audio at a time.") }
        appending = true
        defer {
            appending = false
            let waiters = appendWaiters
            appendWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        try Task.checkCancellation()
        if let failure = await input.recordedFailure() { throw failure }
        guard frame.startTime + 0.000_001 >= lastEnd else {
            throw HolosError.invalidInput("Audio frames must be ordered and nonoverlapping.")
        }
        guard frame.frameCount > 0 else { return }
        guard frame.channels <= 32, frame.frameCount <= Int(UInt32.max),
              frame.startTime * frame.sampleRate < Double(Int64.max) else {
            throw HolosError.invalidInput("PCM frame is too large for the audio converter.")
        }
        let channels = AVAudioChannelCount(frame.channels)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: frame.sampleRate,
                                         channels: channels, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frame.frameCount)),
              let data = buffer.floatChannelData else {
            throw HolosError.invalidInput("Unsupported PCM frame format.")
        }
        buffer.frameLength = AVAudioFrameCount(frame.frameCount)
        for channel in 0..<frame.channels {
            for index in 0..<frame.frameCount {
                data[channel][index] = frame.samples[index * frame.channels + channel]
            }
        }
        let time = AVAudioTime(sampleTime: AVAudioFramePosition((frame.startTime * frame.sampleRate).rounded()),
                               atRate: frame.sampleRate)
        for converted in try converter.convert(buffer, at: time) {
            try await input.send(converted)
        }
        lastEnd = frame.startTime + frame.duration
    }

    public func finish() async throws -> [TranscriptSegment] {
        if cancelled { throw CancellationError() }
        if !ended {
            ended = true
            if appending {
                await withCheckedContinuation { appendWaiters.append($0) }
            }
            if cancelled { throw CancellationError() }
            do {
                if let failure = await input.recordedFailure() { throw failure }
                for converted in try converter.flush() { try await input.send(converted) }
                await input.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
                let reported = await input.recordedFailure()
                await input.finish()
                await analyzer.cancelAndFinishNow()
                resultTask.cancel()
                _ = try? await resultTask.value
                throw reported ?? error
            }
        }
        try await resultTask.value
        if cancelled { throw CancellationError() }
        return await collector.finalSegments()
    }

    public func cancel() async {
        guard !cancelled else { return }
        cancelled = true
        ended = true
        await input.fail(CancellationError())
        await analyzer.cancelAndFinishNow()
        resultTask.cancel()
        _ = try? await resultTask.value
    }
}

private enum Module {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var module: any SpeechModule {
        switch self { case .speech(let value): value; case .dictation(let value): value }
    }
}

private func consume(module: Module, into collector: ResultCollector, analyzer: SpeechAnalyzer,
                     input: BoundedInput<AnalyzerInput>? = nil) -> Task<Void, Error> {
    Task {
        do {
            switch module {
            case .speech(let transcriber):
                for try await result in transcriber.results {
                    await collector.accept(text: result.text, range: result.range,
                                           finalizedThrough: result.resultsFinalizationTime, isFinal: result.isFinal)
                }
            case .dictation(let transcriber):
                for try await result in transcriber.results {
                    await collector.accept(text: result.text, range: result.range,
                                           finalizedThrough: result.resultsFinalizationTime, isFinal: result.isFinal)
                }
            }
            if let input, !(await input.isFinished()) {
                throw HolosError.incomplete("Speech results ended before audio input was finished.")
            }
        } catch {
            if let input { await input.fail(error) }
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}

struct SpeechProbeCounters: Encodable {
    var nativeFinalResults = 0
    var nativeFinalWords = 0
    var nativeVolatileResults = 0
    var acceptedFinalResults = 0
    var acceptedFinalWords = 0
    var droppedFinalResults = 0
    var droppedFinalWords = 0
    var droppedFinalOverlapSeconds = 0.0
    var droppedFinalNovelSeconds = 0.0
    var promotedVolatileResults = 0
    var outputFinalResults = 0
    var outputFinalWords = 0
}

actor ResultCollector {
    private struct Entry { var segment: TranscriptSegment; var isFinal: Bool }
    private var entries: [Entry] = []
    private var counters = SpeechProbeCounters()
    private let onUpdate: @Sendable (TranscriptUpdate) -> Void

    init(onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void) { self.onUpdate = onUpdate }

    func accept(text: AttributedString, range: CMTimeRange, finalizedThrough: CMTime, isFinal: Bool) {
        let raw = String(text.characters)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = max(0, range.start.seconds)
        let end = max(start, range.end.seconds)
        if !trimmed.isEmpty, start.isFinite, end.isFinite {
            let wordCount = raw.split(whereSeparator: { $0.isWhitespace }).count
            if isFinal {
                counters.nativeFinalResults += 1
                counters.nativeFinalWords += wordCount
            } else {
                counters.nativeVolatileResults += 1
            }
            // Results replace volatile hypotheses over their covered audio interval.
            entries.removeAll { !$0.isFinal && $0.segment.start < end && $0.segment.end > start }
            let segment = TranscriptSegment(start: start, end: end, text: raw,
                                            words: timedWords(in: text))
            let overlappingFinals = entries.filter { $0.isFinal && $0.segment.start < end && $0.segment.end > start }
            if overlappingFinals.isEmpty {
                entries.append(Entry(segment: segment, isFinal: isFinal))
                if isFinal {
                    counters.acceptedFinalResults += 1
                    counters.acceptedFinalWords += wordCount
                }
                onUpdate(TranscriptUpdate(segment: segment, isFinal: isFinal))
            } else if isFinal {
                counters.droppedFinalResults += 1
                counters.droppedFinalWords += wordCount
                let overlap = overlappingFinals.reduce(0.0) { sum, entry in
                    sum + max(0, min(end, entry.segment.end) - max(start, entry.segment.start))
                }
                counters.droppedFinalOverlapSeconds += overlap
                counters.droppedFinalNovelSeconds += max(0, end - start - overlap)
            }
        }
        let watermark = finalizedThrough.seconds
        if watermark.isFinite {
            for index in entries.indices where !entries[index].isFinal && entries[index].segment.end <= watermark {
                entries[index].isFinal = true
                counters.promotedVolatileResults += 1
                onUpdate(TranscriptUpdate(segment: entries[index].segment, isFinal: true))
            }
        }
    }

    func finalSegments() -> [TranscriptSegment] {
        // A final flush may close the stream without reissuing the last volatile result.
        for index in entries.indices where !entries[index].isFinal {
            entries[index].isFinal = true
            counters.promotedVolatileResults += 1
            onUpdate(TranscriptUpdate(segment: entries[index].segment, isFinal: true))
        }
        let segments = entries.filter(\.isFinal).map(\.segment).sorted { $0.start < $1.start }
        counters.outputFinalResults = segments.count
        counters.outputFinalWords = segments.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count }
        return segments
    }

    func probeCounters() -> SpeechProbeCounters { counters }
}

func timedWords(in text: AttributedString) -> [TimedWord] {
    var words: [TimedWord] = []
    var offset = 0
    for run in text.runs {
        let runText = String(text[run.range].characters)
        let length = runText.utf16.count
        if let time = run.audioTimeRange, !runText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let start = time.start.seconds
            let end = time.end.seconds
            if start.isFinite, end.isFinite, end > start {
                words.append(TimedWord(text: runText, start: start, end: end,
                                       utf16Offset: offset, utf16Length: length,
                                       confidence: run.transcriptionConfidence))
            }
        }
        offset += length
    }
    return words
}

/// One pending input. A producer suspends until the analyzer consumes it.
actor BoundedInput<Element: Sendable>: AsyncSequence {
    private var pending: Element?
    private var ended = false
    private var failure: (any Error)?
    private var receiver: CheckedContinuation<Element?, Never>?
    private var sender: CheckedContinuation<Void, Never>?

    struct AsyncIterator: AsyncIteratorProtocol {
        let input: BoundedInput<Element>
        mutating func next() async -> Element? { await input.nextInput() }
    }

    nonisolated func makeAsyncIterator() -> AsyncIterator { AsyncIterator(input: self) }

    func send(_ value: Element) async throws {
        try await withTaskCancellationHandler {
            while pending != nil && !ended {
                await withCheckedContinuation { sender = $0 }
            }
            try Task.checkCancellation()
            if let failure { throw failure }
            guard !ended else { throw HolosError.invalidInput("The speech input has ended.") }
            if let receiver {
                self.receiver = nil
                receiver.resume(returning: value)
            } else {
                pending = value
            }
        } onCancel: {
            Task { await self.finish() }
        }
    }

    private func nextInput() async -> Element? {
        if failure != nil { return nil }
        if let pending {
            self.pending = nil
            sender?.resume()
            sender = nil
            return pending
        }
        if ended { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { receiver = $0 }
        } onCancel: {
            Task { await self.finish() }
        }
    }

    func recordedFailure() -> (any Error)? { failure }

    func isFinished() -> Bool { ended }

    func fail(_ error: any Error) {
        if failure == nil { failure = error }
        pending = nil
        finish()
    }

    func finish() {
        ended = true
        receiver?.resume(returning: nil)
        receiver = nil
        sender?.resume()
        sender = nil
    }
}
