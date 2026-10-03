import Foundation
import HolosCore

/// Private, optional visual evidence. Never a vocabulary update or proof of what was spoken.
public struct ScreenTextLine: Codable, Sendable, Equatable {
    public var text: String
    /// Vision's normalized, bottom-left-origin bounding box.
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Float

    public init(text: String, x: Double, y: Double, width: Double, height: Double, confidence: Float) {
        self.text = text; self.x = x; self.y = y; self.width = width; self.height = height
        self.confidence = confidence
    }
}

public struct ScreenKeyframe: Codable, Sendable, Equatable {
    public var id: String
    public var start: Double
    public var end: Double
    public var lines: [ScreenTextLine]?
    public init(id: String = UUID().uuidString, start: Double, end: Double, lines: [ScreenTextLine]? = nil) {
        self.id = id; self.start = start; self.end = end; self.lines = lines
    }
}

public struct ScreenContextRecord: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var sessionID: String
    public var frames: [ScreenKeyframe]
    public var imageBytes = 0
    /// A capture generation fences callbacks abandoned during a bounded stop/restart.
    public var captureID: String?
    /// Fences OCR callbacks abandoned by a bounded batch, cancellation, or a newer worker.
    public var ocrID: String?
    /// A safe status code, never window titles or OCR text.
    public var failure: String?
    public init(sessionID: String, frames: [ScreenKeyframe] = [], failure: String? = nil) {
        self.sessionID = sessionID; self.frames = frames; self.failure = failure
    }

    /// Evidence only while the frame was actually observed, never across a pause or capture failure.
    public func words(from start: Double, to end: Double, maximumCharacters: Int = 800) -> [String] {
        guard start.isFinite, end.isFinite, end >= start, maximumCharacters > 0 else { return [] }
        var seen: Set<String> = [], result: [String] = [], count = 0
        for frame in frames where frame.start <= end && frame.end >= start {
            for line in frame.lines ?? [] where line.confidence >= 0.6 {
                let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
                guard count + text.count <= maximumCharacters else { continue }
                result.append(text); count += text.count
            }
        }
        return result
    }

    /// Suggestions for user review; this API does not add anything to the word list.
    public func candidates(excluding known: [String], from start: Double, to end: Double) -> [String] {
        let known = Set(known.map { $0.lowercased() })
        return words(from: start, to: end).flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
            .filter { $0.count >= 3 && $0.contains(where: \.isLetter) && !known.contains($0.lowercased()) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }
}

public enum ScreenContextStore {
    public static let maximumFrames = 1_000
    public static let maximumImageBytes = 1 << 20
    public static let maximumTotalImageBytes = 256 << 20
    /// Snapshots are of the whole display, downscaled so neither side exceeds this: about point resolution on a 5K
    /// display, so slide text stays legible to OCR.
    public static let maximumImageDimension = 2560
    public static func directory(_ session: URL) -> URL { session.appendingPathComponent("screen", isDirectory: true) }
    public static func manifest(_ session: URL) -> URL { directory(session).appendingPathComponent("context.json") }
    public static func image(_ id: String, session: URL) throws -> URL {
        guard UUID(uuidString: id) != nil, SessionArchive.validToken(id) else {
            throw HolosError.invalidInput("Invalid screen keyframe ID.")
        }
        return directory(session).appendingPathComponent("\(id).jpg")
    }

    public static func read(session: URL, sessionID: String) throws -> ScreenContextRecord? {
        guard let data = try AtomicFile.readIfPresent(manifest(session), maxBytes: 16 << 20) else { return nil }
        let record = try SchemaVersion.decode(ScreenContextRecord.self, from: data, current: 1, name: "screen/context.json")
        guard record.sessionID == sessionID, record.frames.count <= maximumFrames,
              record.imageBytes >= 0, record.imageBytes <= maximumTotalImageBytes else {
            throw HolosError.invalidInput("Screen context belongs to another session or has too many frames.")
        }
        var lastEnd = 0.0, ids: Set<String> = []
        for frame in record.frames {
            _ = try image(frame.id, session: session)
            guard ids.insert(frame.id).inserted, frame.start.isFinite, frame.end.isFinite,
                  frame.start >= lastEnd, frame.end >= frame.start,
                  (frame.lines?.count ?? 0) <= 256 else {
                throw HolosError.invalidInput("Screen context has invalid times or text.")
            }
            for line in frame.lines ?? [] {
                guard line.text.count <= 1000, line.confidence.isFinite, (0...1).contains(line.confidence),
                      [line.x, line.y, line.width, line.height].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw HolosError.invalidInput("Screen context has invalid text bounds.")
                }
            }
            lastEnd = frame.end
        }
        return record
    }

    /// Candidate filtering is optional: a damaged/newer/unreadable word list never hides valid screen evidence.
    public static func readForReview(session: URL, sessionID: String, knownTerms: () throws -> [String]) throws
        -> (record: ScreenContextRecord?, known: [String]?) {
        (try read(session: session, sessionID: sessionID), try? knownTerms())
    }

    public static func write(_ record: ScreenContextRecord, session: URL) throws {
        try AtomicFile.ensurePrivateDirectory(directory(session))
        try AtomicFile.writeJSON(record, to: manifest(session))
    }

    /// Serial compare-and-update under the existing session metadata lock. Capture and OCR workers call this off
    /// the main actor; it also prevents late abandoned callbacks from recreating evidence after Delete Audio.
    @discardableResult public static func update(session: URL, sessionID: String,
        _ change: (inout ScreenContextRecord) throws -> Void) throws -> ScreenContextRecord {
        try SessionArchive.withSpeakerLock(at: session) {
            guard try SessionArchive.readManifest(at: session).id == sessionID else {
                throw HolosError.invalidInput("Screen context session identity mismatch.")
            }
            guard try !AudioDeletedRecord.isDeleted(session: session, sessionID: sessionID) else {
                throw HolosError.unavailable("Screen evidence was deleted with this meeting's audio.")
            }
            var record = try read(session: session, sessionID: sessionID) ?? ScreenContextRecord(sessionID: sessionID)
            try change(&record)
            try write(record, session: session)
            return record
        }
    }
}
