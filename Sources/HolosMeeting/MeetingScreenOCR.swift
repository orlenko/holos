import CoreGraphics
import Foundation
import HolosCore
import HolosStorage
import ImageIO
import Vision

/// On-device, resumable OCR, only after capture has stopped. No model calls or vocabulary writes.
public enum MeetingScreenOCR {
    public typealias Recognizer = @Sendable (CGImage, [String]) throws -> [ScreenTextLine]

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
        let job = Task.detached(priority: .utility) {
            guard var record = try ScreenContextStore.read(session: session, sessionID: sessionID) else { return }
            record = try ScreenContextStore.update(session: session, sessionID: sessionID) { $0.captureID = nil }
            for index in record.frames.indices where record.frames[index].lines == nil {
                try Task.checkCancellation()
                let url = try ScreenContextStore.image(record.frames[index].id, session: session)
                guard let data = try AtomicFile.readIfPresent(url, maxBytes: ScreenContextStore.maximumImageBytes),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      (1...1600).contains(width), (1...1600).contains(height),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    record.failure = "imageUnavailable"
                    try ScreenContextStore.update(session: session, sessionID: sessionID) { $0.failure = "imageUnavailable" }
                    continue
                }
                record.frames[index].lines = try recognizer(image, languages)
                try Task.checkCancellation()
                let frame = record.frames[index]
                try ScreenContextStore.update(session: session, sessionID: sessionID) { current in
                    if let position = current.frames.firstIndex(where: { $0.id == frame.id }) {
                        current.frames[position].lines = frame.lines
                    }
                }
            }
        }
        try await withTaskCancellationHandler { try await job.value } onCancel: { job.cancel() }
    }
}
