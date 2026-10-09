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

/// The display a keyframe came from, as the meeting knows it (docs/meeting/screen-context.md §4.15). The same physical display
/// keeps its number for the whole meeting, also in the recorder's next capture epoch (after a pause, say).
public struct ScreenDisplay: Codable, Sendable, Equatable, Hashable {
    /// The `CGDirectDisplayID`: stable for one physical display while it stays connected, and usually across a
    /// reconnect.
    public var id: UInt32
    /// 1 and up, for this meeting: the displays connected when capture began are numbered by their arrangement (left
    /// to right, then top to bottom); one connected later takes the next number.
    public var number: Int
    /// The main display (the one with the menu bar) when its capture began.
    public var isMain: Bool

    public init(id: UInt32, number: Int, isMain: Bool) {
        self.id = id; self.number = number; self.isMain = isMain
    }

    /// "Main display", or "Display 2". With more than one main display in a meeting (the main one changed), "Display
    /// 2, main" keeps them apart.
    public func label(severalMain: Bool = false) -> String {
        guard isMain else { return "Display \(number)" }
        return severalMain ? "Display \(number), main" : "Main display"
    }
}

public struct ScreenKeyframe: Codable, Sendable, Equatable {
    public var id: String
    public var start: Double
    public var end: Double
    public var lines: [ScreenTextLine]?
    /// Where the snapshot came from; nil in a meeting captured before all displays were (only the main display was
    /// then), which `source` reads as the main display.
    public var display: ScreenDisplay?
    /// The JPEG's size, so the shared caps know each display's share exactly in the recorder's next capture epoch;
    /// nil for a keyframe saved before keyframes said.
    public var bytes: Int?
    public init(id: String = UUID().uuidString, start: Double, end: Double, lines: [ScreenTextLine]? = nil,
                display: ScreenDisplay? = nil, bytes: Int? = nil) {
        self.id = id; self.start = start; self.end = end; self.lines = lines; self.display = display
        self.bytes = bytes
    }

    /// The display the snapshot came from; the main display for a keyframe saved before keyframes said.
    public var source: ScreenDisplay { display ?? ScreenDisplay(id: 0, number: 1, isMain: true) }
}

public struct ScreenContextRecord: Codable, Sendable, Equatable {
    /// The version written: 2 once a keyframe names its display or size, 1 otherwise. A build from before displays
    /// were named (it reads only 1) refuses a version-2 file as "written by a newer version" and leaves it alone:
    /// its OCR or Review would otherwise rewrite the file without the fields it does not know, and every snapshot
    /// would then read as the main display's. A record without those fields (one saved before, even after this
    /// build recognized its text) stays at 1, so an older build can still read it.
    public var schemaVersion: Int {
        frames.contains { $0.display != nil || $0.bytes != nil } ? 2 : 1
    }
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

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sessionID, frames, imageBytes, captureID, ocrID, failure
    }

    /// `schemaVersion` is checked before decoding (`ScreenContextStore.read`) and follows from the keyframes.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Required, as before the version followed from the keyframes: a file without a readable version is damaged.
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...ScreenContextStore.schemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                   debugDescription: "Unsupported screen context schema version.")
        }
        sessionID = try container.decode(String.self, forKey: .sessionID)
        frames = try container.decode([ScreenKeyframe].self, forKey: .frames)
        imageBytes = try container.decodeIfPresent(Int.self, forKey: .imageBytes) ?? 0
        captureID = try container.decodeIfPresent(String.self, forKey: .captureID)
        ocrID = try container.decodeIfPresent(String.self, forKey: .ocrID)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(frames, forKey: .frames)
        try container.encode(imageBytes, forKey: .imageBytes)
        try container.encodeIfPresent(captureID, forKey: .captureID)
        try container.encodeIfPresent(ocrID, forKey: .ocrID)
        try container.encodeIfPresent(failure, forKey: .failure)
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

    /// The displays the keyframes came from, by first appearance; one for a meeting captured on one display (or
    /// before keyframes named their display).
    public var displays: [ScreenDisplay] {
        var seen: Set<UInt32> = [], result: [ScreenDisplay] = []
        for frame in frames where seen.insert(frame.display?.id ?? 0).inserted { result.append(frame.source) }
        return result
    }

    /// Which display a keyframe came from, for Review: nil when the meeting has one display, so nothing extra shows.
    public func displayLabel(_ frame: ScreenKeyframe) -> String? {
        guard displays.count > 1 else { return nil }
        return frame.source.label(severalMain: severalMainDisplays)
    }

    /// `displayLabel` of every keyframe, in order, working out the displays once.
    public var displayLabels: [String?] {
        guard displays.count > 1 else { return frames.map { _ in nil } }
        let severalMain = severalMainDisplays
        return frames.map { $0.source.label(severalMain: severalMain) }
    }

    /// More than one display was the main one in some keyframe (the main display changed during the meeting, say
    /// across a pause), so "Main display" alone would not tell them apart.
    private var severalMainDisplays: Bool {
        Set(frames.filter(\.source.isMain).map { $0.display?.id ?? 0 }).count > 1
    }

    /// Where a new keyframe starting at `start` goes: after every keyframe that starts no later, so the shared
    /// timeline stays in start order while displays' intervals overlap.
    public func insertionIndex(start: Double) -> Int {
        (frames.lastIndex { $0.start <= start }).map { $0 + 1 } ?? 0
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
    /// The newest `screen/context.json` version this build reads (`ScreenContextRecord.schemaVersion`).
    public static let schemaVersion = 2
    public static let maximumFrames = 1_000
    public static let maximumImageBytes = 1 << 20
    public static let maximumTotalImageBytes = 256 << 20
    /// The highest display number a keyframe may carry: far more displays than one Mac drives, still bounded on read.
    public static let maximumDisplays = 64
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
        let record = try SchemaVersion.decode(ScreenContextRecord.self, from: data, current: schemaVersion, name: "screen/context.json")
        guard record.sessionID == sessionID, record.frames.count <= maximumFrames,
              record.imageBytes >= 0, record.imageBytes <= maximumTotalImageBytes else {
            throw HolosError.invalidInput("Screen context belongs to another session or has too many frames.")
        }
        // Each display's keyframes follow one another without overlapping; different displays' overlap in time. A
        // keyframe without a display (saved before keyframes said) is the main display's.
        // All of them are listed in start order: Review lists them so, and new keyframes are inserted by start.
        var lastEnd: [UInt32?: Double] = [:], lastStart = 0.0, ids: Set<String> = []
        for frame in record.frames {
            _ = try image(frame.id, session: session)
            let display = frame.display?.id
            guard ids.insert(frame.id).inserted, frame.start.isFinite, frame.end.isFinite,
                  frame.start >= lastEnd[display, default: 0], frame.start >= lastStart, frame.end >= frame.start,
                  (frame.display?.number).map({ (1...maximumDisplays).contains($0) }) ?? true,
                  frame.bytes.map({ (0...maximumImageBytes).contains($0) }) ?? true,
                  (frame.lines?.count ?? 0) <= 256 else {
                throw HolosError.invalidInput("Screen context has invalid times or text.")
            }
            for line in frame.lines ?? [] {
                guard line.text.count <= 1000, line.confidence.isFinite, (0...1).contains(line.confidence),
                      [line.x, line.y, line.width, line.height].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                    throw HolosError.invalidInput("Screen context has invalid text bounds.")
                }
            }
            lastEnd[display] = frame.end
            lastStart = frame.start
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
