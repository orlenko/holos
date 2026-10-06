import CoreGraphics
import Foundation
import HolosCore
import HolosStorage
import ImageIO
import Vision

/// On-device, resumable OCR, only after capture has stopped. No model calls or vocabulary writes.
public enum MeetingScreenOCR {
    public typealias Recognizer = @Sendable (CGImage, [String]) throws -> [ScreenTextLine]
    public static let batchFrames = 8
    public static let batchTimeout: Duration = .seconds(5)
    /// Synthetic tests release a stalled recognizer and trigger the deadline by event, not elapsed-time assertions.
    @TaskLocal static var deadlineForTesting: SharedDeadline? = nil
    @TaskLocal static var didEndForTesting: (@Sendable () -> Void)? = nil
    /// Synthetic tests that run a bounded batch through a caller with its own limit (the post-processor) give every
    /// batch this limit instead, one no load reaches, so recognition that must finish never races a real 5 s timer.
    @TaskLocal static var batchTimeoutForTesting: Duration? = nil

    public static func recognize(_ image: CGImage, languages: [String]) throws -> [ScreenTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let supported = try request.supportedRecognitionLanguages()
        let chosen = languages.compactMap { language in
            supported.first(where: { $0.caseInsensitiveCompare(language) == .orderedSame })
                ?? supported.first(where: { $0.split(separator: "-").first == language.split(separator: "-").first })
        }
        if !chosen.isEmpty { request.recognitionLanguages = Array(Set(chosen)).sorted() }
        try VNImageRequestHandler(cgImage: image).perform([request])
        var characters = 0
        return (request.results ?? []).prefix(64).compactMap { observation in
            guard let text = observation.topCandidates(1).first else { return nil }
            let content = String(text.string.prefix(min(1000, max(0, 4000 - characters))))
            guard !content.isEmpty else { return nil }
            characters += content.count
            let box = observation.boundingBox
            return ScreenTextLine(text: content, x: box.minX, y: box.minY,
                                  width: box.width, height: box.height, confidence: text.confidence)
        }
    }

    /// Caller holds the session's writer or processing lease. Each completed frame is durable; cancellation can
    /// resume later. Safe AtomicFile reads prevent a planted image symlink from reading outside the session.
    public static func process(session: URL, sessionID: String, languages: [String],
                               recognizer: @escaping Recognizer = { try recognize($0, languages: $1) }) async throws {
        try await perform(session: session, sessionID: sessionID, languages: languages, generation: UUID().uuidString,
                          maximumFrames: .max, recognizer: recognizer)
    }

    /// Recorder/recovery and Review use small resumable batches. Timeout abandons even a synchronous Vision call;
    /// completed frames stay durable and an abandoned generation cannot publish later or overwrite its successor.
    /// Returns whether every saved frame now has OCR. Caller holds the writer/processing lease.
    public static func processBounded(session: URL, sessionID: String, languages: [String],
        timeout: Duration = batchTimeout, maximumFrames: Int = batchFrames,
        recognizer: @escaping Recognizer = { try recognize($0, languages: $1) }) async throws -> Bool {
        let generation = UUID().uuidString
        let result = await awaitWithTimeout(batchTimeoutForTesting ?? timeout, deadline: deadlineForTesting) {
            try await perform(session: session, sessionID: sessionID, languages: languages, generation: generation,
                              maximumFrames: max(0, maximumFrames), recognizer: recognizer)
        }
        // Revoke before returning, not when a possibly hung native recognizer eventually exits.
        await Task.detached(priority: .utility) {
            guard (try? ScreenContextStore.read(session: session, sessionID: sessionID)) != nil else { return }
            try? ScreenContextStore.update(session: session, sessionID: sessionID) {
                if $0.ocrID == generation { $0.ocrID = nil }
            }
        }.value
        switch result {
        case .finished(let outcome): try outcome.get()
        case .cancelled: throw CancellationError()
        case .timedOut: return false
        }
        return try await Task.detached(priority: .utility) {
            try ScreenContextStore.read(session: session, sessionID: sessionID)?.frames.allSatisfy { $0.lines != nil } ?? true
        }.value
    }

    private static func perform(session: URL, sessionID: String, languages: [String], generation: String,
                                maximumFrames: Int, recognizer: @escaping Recognizer) async throws {
        let didEnd = didEndForTesting
        let job = Task.detached(priority: .utility) {
            defer { didEnd?() }
            try Task.checkCancellation()
            guard var record = try ScreenContextStore.read(session: session, sessionID: sessionID) else { return }
            guard maximumFrames > 0, record.frames.contains(where: { $0.lines == nil }) else { return }
            record = try ScreenContextStore.update(session: session, sessionID: sessionID) {
                try Task.checkCancellation()
                $0.captureID = nil; $0.ocrID = generation
            }
            defer {
                try? ScreenContextStore.update(session: session, sessionID: sessionID) {
                    if $0.ocrID == generation { $0.ocrID = nil }
                }
            }
            let pending = record.frames.indices.filter { record.frames[$0].lines == nil }.prefix(maximumFrames)
            for index in pending {
                try Task.checkCancellation()
                let url = try ScreenContextStore.image(record.frames[index].id, session: session)
                guard let data = try AtomicFile.readIfPresent(url, maxBytes: ScreenContextStore.maximumImageBytes),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (1...ScreenContextStore.maximumImageDimension).contains(width),
                      (1...ScreenContextStore.maximumImageDimension).contains(height),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    record.failure = "imageUnavailable"
                    try ScreenContextStore.update(session: session, sessionID: sessionID) {
                        try Task.checkCancellation()
                        guard $0.ocrID == generation else { throw CancellationError() }
                        $0.failure = "imageUnavailable"
                    }
                    continue
                }
                record.frames[index].lines = try recognizer(image, languages)
                try Task.checkCancellation()
                let frame = record.frames[index]
                try ScreenContextStore.update(session: session, sessionID: sessionID) { current in
                    try Task.checkCancellation()
                    guard current.ocrID == generation else { throw CancellationError() }
                    if let position = current.frames.firstIndex(where: { $0.id == frame.id }) {
                        current.frames[position].lines = frame.lines
                    }
                }
            }
        }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}
