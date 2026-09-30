import Foundation
import HolosAudio
import HolosCore
import HolosStorage

/// Where the evaluation keeps its files in a session folder (docs/reference-evaluation.md, "Cloud reference"). Only
/// the `voiceislocal eval` commands read them; the app, the exports, and every other command ignore `eval/`.
///
/// ```
/// eval/cloud/<run>/run.json              the plan, the request fields (never the key), progress
/// eval/cloud/<run>/segments/<track>-<n>.json   each segment's parsed result, saved as soon as it arrives
/// eval/cloud/<run>/raw/<track>-<n>.json        the model's raw response body
/// eval/cloud/<run>/timestamps/…, raw-timestamps/…   the optional whisper-1 pass
/// eval/cloud/<run>/<track>.json          the stitched track, once every segment is in
/// eval/compare/<run>/report.md, report.json
/// eval/review/<run>/review.html, review-audio/<track>.m4a
/// eval/gold/<run>.json
/// derived/eval-cloud/<run>/              renders and segment files while a run uploads (removed after)
/// ```
public enum EvalPaths {
    public static func root(_ session: URL) -> URL { session.appendingPathComponent("eval", isDirectory: true) }
    public static func cloudRoot(_ session: URL) -> URL { root(session).appendingPathComponent("cloud", isDirectory: true) }
    public static func cloudRun(_ id: String, in session: URL) -> URL {
        cloudRoot(session).appendingPathComponent(id, isDirectory: true)
    }
    public static func runRecord(_ id: String, in session: URL) -> URL {
        cloudRun(id, in: session).appendingPathComponent("run.json")
    }
    public static func segmentResult(_ id: String, track: String, index: Int, timestamps: Bool = false,
                                     in session: URL) -> URL {
        cloudRun(id, in: session).appendingPathComponent(timestamps ? "timestamps" : "segments", isDirectory: true)
            .appendingPathComponent("\(track)-\(String(format: "%03d", index)).json")
    }
    public static func rawResponse(_ id: String, track: String, index: Int, timestamps: Bool = false,
                                   in session: URL) -> URL {
        cloudRun(id, in: session).appendingPathComponent(timestamps ? "raw-timestamps" : "raw", isDirectory: true)
            .appendingPathComponent("\(track)-\(String(format: "%03d", index)).json")
    }
    public static func trackResult(_ id: String, track: String, in session: URL) -> URL {
        cloudRun(id, in: session).appendingPathComponent("\(track).json")
    }
    public static func compare(_ id: String, in session: URL) -> URL {
        root(session).appendingPathComponent("compare", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
    public static func review(_ id: String, in session: URL) -> URL {
        root(session).appendingPathComponent("review", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
    public static func reviewAudio(_ id: String, in session: URL) -> URL {
        review(id, in: session).appendingPathComponent("review-audio", isDirectory: true)
    }
    public static func gold(_ id: String, in session: URL) -> URL {
        root(session).appendingPathComponent("gold", isDirectory: true).appendingPathComponent("\(id).json")
    }
    /// Temporary audio of a run, under derived/ so Delete Audio removes it with the rest of the audio.
    public static func work(_ id: String, in session: URL) -> URL {
        SessionPaths.derived(session).appendingPathComponent("eval-cloud", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }
}

/// A span of a render's time map (`RenderSpan`), as saved.
public struct EvalSpan: Codable, Sendable, Equatable {
    public var renderStart: Double
    public var sessionStart: Double
    public var duration: Double

    public init(_ span: RenderSpan) {
        renderStart = span.renderStart; sessionStart = span.sessionStart; duration = span.duration
    }

    public var span: RenderSpan { RenderSpan(renderStart: renderStart, sessionStart: sessionStart, duration: duration) }
}

public enum EvalTimeMap {
    /// Session time of render time `time`.
    public static func sessionTime(_ time: Double, map: [EvalSpan]) -> Double {
        RenderTimeMap.sessionTime(time, map: map.map(\.span))
    }

    /// Render time of session time `time`: linear inside a span; a time in a shortened gap goes to the start of the
    /// next span (or the end of the last).
    public static func renderTime(_ time: Double, map: [EvalSpan]) -> Double {
        guard !map.isEmpty, time.isFinite else { return time }
        for span in map {
            if time < span.sessionStart { return span.renderStart }
            if time <= span.sessionStart + span.duration { return span.renderStart + (time - span.sessionStart) }
        }
        let last = map[map.count - 1]
        return last.renderStart + last.duration
    }
}

/// One track of a cloud run: its render and the segments cut from it.
public struct CloudTrackPlan: Codable, Sendable, Equatable {
    public var track: String
    public var sampleRate: Double
    public var frameCount: Int
    public var timeMap: [EvalSpan]
    /// SHA-256 of the track's chunk list: a resumed run renders the same audio only if it is unchanged.
    public var audioFingerprint: String
    public var segments: [CloudSegmentPlan]

    public init(track: String, sampleRate: Double, frameCount: Int, timeMap: [EvalSpan], audioFingerprint: String,
                segments: [CloudSegmentPlan]) {
        self.track = track; self.sampleRate = sampleRate; self.frameCount = frameCount; self.timeMap = timeMap
        self.audioFingerprint = audioFingerprint; self.segments = segments
    }

    public func renderStart(_ segment: CloudSegmentPlan) -> Double { Double(segment.startFrame) / sampleRate }
    public func renderEnd(_ segment: CloudSegmentPlan) -> Double { Double(segment.endFrame) / sampleRate }
    public func sessionStart(_ segment: CloudSegmentPlan) -> Double {
        EvalTimeMap.sessionTime(renderStart(segment), map: timeMap)
    }
    public func sessionEnd(_ segment: CloudSegmentPlan) -> Double {
        EvalTimeMap.sessionTime(renderEnd(segment), map: timeMap)
    }
    /// Seconds uploaded: the segments that are not silent.
    public var uploadSeconds: Double {
        segments.filter { !$0.silent }.reduce(0) { $0 + $1.seconds(sampleRate: sampleRate) }
    }
}

/// eval/cloud/<run>/run.json.
public struct CloudRunRecord: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var id: String
    public var sessionID: String
    public var createdAt: Date
    /// The request fields each segment is sent with (the key is never saved).
    public var request: CloudRequestFields
    /// The optional whisper-1 timestamp pass's fields, when it was asked for.
    public var timestampRequest: CloudRequestFields?
    public var vocabulary: Bool
    public var maxSegmentSeconds: Double
    public var tracks: [CloudTrackPlan]
    /// Set once every segment's result is saved and the tracks are stitched.
    public var completedAt: Date?

    public init(id: String, sessionID: String, createdAt: Date, request: CloudRequestFields,
                timestampRequest: CloudRequestFields?, vocabulary: Bool, maxSegmentSeconds: Double,
                tracks: [CloudTrackPlan]) {
        self.id = id; self.sessionID = sessionID; self.createdAt = createdAt; self.request = request
        self.timestampRequest = timestampRequest; self.vocabulary = vocabulary
        self.maxSegmentSeconds = maxSegmentSeconds; self.tracks = tracks
    }

    public var model: String { request.model }
    public var uploadSeconds: Double { tracks.reduce(0) { $0 + $1.uploadSeconds } }
    public var uploadCount: Int { tracks.reduce(0) { $0 + $1.segments.filter { !$0.silent }.count } }
}

/// eval/cloud/<run>/segments/<track>-<n>.json: one segment's parsed result.
public struct CloudSegmentRecord: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var track: String
    public var index: Int
    public var model: String
    public var result: CloudTranscriptionResult
    public var attempts: Int
    public var receivedAt: Date

    public init(track: String, index: Int, model: String, result: CloudTranscriptionResult, attempts: Int,
                receivedAt: Date) {
        self.track = track; self.index = index; self.model = model; self.result = result; self.attempts = attempts
        self.receivedAt = receivedAt
    }
}

/// eval/cloud/<run>/<track>.json: the track's cloud transcript, segment by segment.
public struct CloudTrackResult: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Equatable {
        public var index: Int
        public var sessionStart: Double
        public var sessionEnd: Double
        public var renderStart: Double
        public var renderEnd: Double
        public var overlapSeconds: Double
        public var silent: Bool
        /// The model's text for the whole segment.
        public var text: String
        /// Its words without those the previous segment's overlap already had (`CloudSegmentation.stitch`).
        public var words: [String]
        /// whisper-1 word timings in session time, when the timestamp pass ran.
        public var timedWords: [CloudTranscriptionResult.Word]?
    }

    public var schemaVersion = 1
    public var run: String
    public var track: String
    public var model: String
    public var segments: [Segment]
    public var text: String
}

public enum EvalStore {
    static let maxRecordBytes = 64 << 20

    /// A run ID: "<model>-<UTC yyyyMMdd'T'HHmmss'Z'>".
    public static func newRunID(model: String, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "\(model)-\(formatter.string(from: date))"
    }

    /// Refuses a run ID that is not a plain token (letters, digits, "-", "_"), so it can never name a path elsewhere.
    public static func checkRunID(_ id: String) throws {
        guard SessionArchive.validToken(id), id.count <= 128 else {
            throw HolosError.invalidInput("\(id) is not an evaluation run ID (see voiceislocal eval list).")
        }
    }

    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try AtomicFile.ensurePrivateDirectory(url.deletingLastPathComponent())
        try AtomicFile.write(HolosJSON.encoder().encode(value), to: url)
    }

    public static func writeData(_ data: Data, to url: URL) throws {
        try AtomicFile.ensurePrivateDirectory(url.deletingLastPathComponent())
        try AtomicFile.write(data, to: url)
    }

    public static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard let data = try AtomicFile.readIfPresent(url, maxBytes: maxRecordBytes) else { return nil }
        do {
            return try HolosJSON.decoder().decode(type, from: data)
        } catch {
            throw HolosError.invalidInput("\(url.lastPathComponent) is damaged or was not written by voiceislocal eval.")
        }
    }

    /// eval/cloud/<id>/run.json. A record that names another run, has a track name that is not a plain token, or
    /// belongs to another session (when `sessionID` is given) is refused: its names become paths.
    public static func runRecord(_ id: String, in session: URL, sessionID: String? = nil) throws -> CloudRunRecord? {
        try checkRunID(id)
        guard let record = try read(CloudRunRecord.self, from: EvalPaths.runRecord(id, in: session)) else { return nil }
        guard record.id == id, record.tracks.allSatisfy({ SessionArchive.validToken($0.track) }),
              CloudModels.isValidName(record.request.model) else {
            throw HolosError.invalidInput("eval/cloud/\(id)/run.json does not describe run \(id).")
        }
        let owner = try sessionID ?? SessionArchive.readManifest(at: session).id
        guard record.sessionID == owner else {
            throw HolosError.invalidInput("Run \(id) belongs to another session.")
        }
        return record
    }

    public static func segment(_ id: String, track: String, index: Int, timestamps: Bool = false,
                               in session: URL) throws -> CloudSegmentRecord? {
        try read(CloudSegmentRecord.self,
                 from: EvalPaths.segmentResult(id, track: track, index: index, timestamps: timestamps, in: session))
    }

    /// Run IDs under eval/cloud/, oldest first (IDs end with their UTC time).
    public static func runIDs(in session: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: EvalPaths.cloudRoot(session).path)) ?? []
        return names.filter { SessionArchive.validToken($0) }
            .sorted { ($0.suffix(16), $0) < ($1.suffix(16), $1) }
    }

    /// The run a command names, or the newest complete one (newest of all when `requireComplete` is false).
    public static func resolveRun(_ id: String?, in session: URL, requireComplete: Bool = true) throws -> CloudRunRecord {
        if let id {
            guard let record = try runRecord(id, in: session) else {
                throw HolosError.invalidInput("There is no evaluation run \(id) in this session (see voiceislocal eval list).")
            }
            if requireComplete, record.completedAt == nil {
                throw HolosError.incomplete("Run \(id) has not finished uploading; run voiceislocal eval cloud again to resume it.")
            }
            return record
        }
        for candidate in runIDs(in: session).reversed() {
            guard let record = try? runRecord(candidate, in: session) else { continue }
            if !requireComplete || record.completedAt != nil { return record }
        }
        throw HolosError.invalidInput("This session has no finished cloud run yet; run voiceislocal eval cloud first.")
    }

    /// How many of a run's segments (not silent) have a saved result.
    public static func savedSegments(_ record: CloudRunRecord, in session: URL) -> Int {
        var count = 0
        for track in record.tracks {
            for segment in track.segments where !segment.silent {
                let url = EvalPaths.segmentResult(record.id, track: track.track, index: segment.index, in: session)
                if FileManager.default.fileExists(atPath: url.path) { count += 1 }
            }
        }
        return count
    }

    /// Removes one run's files everywhere under eval/ and its temporary audio. Returns whether anything was there.
    @discardableResult
    public static func deleteRun(_ id: String, in session: URL) throws -> Bool {
        try checkRunID(id)
        var removed = false
        if EvalLocal.isLocalRunID(id) {
            // A local candidate, and its comparisons with every cloud run.
            if try AtomicFile.removeTree(["eval", "local", id], in: session) { removed = true }
            for cloud in runIDs(in: session) where try AtomicFile.removeTree(["eval", "compare", cloud, id], in: session) {
                removed = true
            }
            return removed
        }
        for components in [["eval", "cloud", id], ["eval", "compare", id], ["eval", "review", id],
                           ["derived", "eval-cloud", id]] {
            if try AtomicFile.removeTree(components, in: session) { removed = true }
        }
        let gold = EvalPaths.gold(id, in: session)
        if AtomicFile.removeRegularFile(gold) { removed = true }
        var info = stat()
        if lstat(gold.path, &info) == 0 {
            throw HolosError.io("Could not delete \(gold.path); delete it by hand.")
        }
        return removed
    }

    /// Removes eval/ and every run's temporary audio.
    @discardableResult
    public static func deleteAll(in session: URL) throws -> Bool {
        let first = try AtomicFile.removeTree(["eval"], in: session)
        let second = try AtomicFile.removeTree(["derived", "eval-cloud"], in: session)
        return first || second
    }

    /// SHA-256 of a track's chunk list (IDs, times, frame counts, sample rates, and each chunk's content hash as the
    /// manifest records it).
    public static func audioFingerprint(manifest: SessionManifest, track: String) -> String {
        let lines = manifest.chunks.filter { $0.track == track }
            .sorted { ($0.start, $0.relativePath) < ($1.start, $1.relativePath) }
            .map {
                "\($0.id) \($0.relativePath) \($0.start) \($0.end) \($0.frameCount) \($0.sampleRate) \($0.channels) "
                    + ($0.sha256 ?? "-")
            }
        return SessionExports.sha256(Data(lines.joined(separator: "\n").utf8))
    }
}
