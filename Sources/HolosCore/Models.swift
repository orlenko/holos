import Foundation

public enum HolosError: Error, LocalizedError, Sendable {
    case invalidInput(String)
    case unavailable(String)
    case permissionDenied(String)
    case incomplete(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let message), .unavailable(let message), .permissionDenied(let message),
             .incomplete(let message), .io(let message): message
        }
    }
}

/// Immutable owned samples. Interleaved Float32; startTime is relative to the session clock.
public struct PCMFrame: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let channels: Int
    public let startTime: Double

    public init(samples: [Float], sampleRate: Double, channels: Int, startTime: Double) throws {
        guard sampleRate.isFinite, sampleRate > 0, channels > 0,
              samples.count.isMultiple(of: channels), startTime.isFinite, startTime >= 0 else {
            throw HolosError.invalidInput("Invalid PCM frame format or timestamp.")
        }
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
        self.startTime = startTime
    }

    public var frameCount: Int { samples.count / channels }
    public var duration: Double { Double(frameCount) / sampleRate }
}

public enum SpeechBackend: String, Codable, Sendable, CaseIterable {
    case speech
    case dictation
}

public struct TimedWord: Codable, Sendable, Equatable {
    public var text: String
    public var start: Double
    public var end: Double
    public var utf16Offset: Int
    public var utf16Length: Int
    public var confidence: Double?

    public init(text: String, start: Double, end: Double, utf16Offset: Int, utf16Length: Int, confidence: Double? = nil) {
        self.text = text; self.start = start; self.end = end
        self.utf16Offset = utf16Offset; self.utf16Length = utf16Length; self.confidence = confidence
    }
}

public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [TimedWord]
    public var track: String?
    public var speakerID: String?
    /// The language this segment was transcribed in ("fr-CA"), in a transcript merged from several languages
    /// (`Transcript.languages`, docs/meeting-design.md §4.14); nil in a transcript made in one language.
    public var language: String?

    public init(id: String = UUID().uuidString, start: Double, end: Double, text: String,
                words: [TimedWord] = [], track: String? = nil, speakerID: String? = nil, language: String? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text
        self.words = words; self.track = track; self.speakerID = speakerID; self.language = language
    }
}

public struct TranscriptUpdate: Sendable {
    public let segment: TranscriptSegment
    public let isFinal: Bool

    public init(segment: TranscriptSegment, isFinal: Bool) {
        self.segment = segment; self.isFinal = isFinal
    }
}

public struct Transcript: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var id: String
    public var createdAt: Date
    public var source: String
    public var locale: String
    public var backend: SpeechBackend
    public var segments: [TranscriptSegment]
    /// For a transcript merged from one transcription per language (docs/meeting-design.md §4.14): the languages it
    /// chose from, the first one (`locale`) preferred on a tie; each segment names its own (`language`). Nil for a
    /// transcript made in `locale` alone.
    public var languages: [String]?

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), source: String,
                locale: String, backend: SpeechBackend, segments: [TranscriptSegment] = [],
                languages: [String]? = nil) {
        self.id = id; self.createdAt = createdAt; self.source = source
        self.locale = locale; self.backend = backend; self.segments = segments; self.languages = languages
    }

    public var text: String { segments.map(\.text).joined(separator: " ") }
}

public struct SpeechCapabilities: Codable, Sendable {
    public var backend: SpeechBackend
    public var isAvailable: Bool
    public var supportedLocales: [String]
    public var installedLocales: [String]

    public init(backend: SpeechBackend, isAvailable: Bool, supportedLocales: [String], installedLocales: [String]) {
        self.backend = backend; self.isAvailable = isAvailable
        self.supportedLocales = supportedLocales; self.installedLocales = installedLocales
    }
}

public enum AudioSource: String, Codable, Sendable, CaseIterable {
    case microphone = "mic"
    case system
    case microphoneAndSystem = "mic+system"
}

public enum HolosPaths {
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Holos", isDirectory: true)
    }

    public static var sessions: URL {
        if let path = ProcessInfo.processInfo.environment["HOLOS_DATA_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return applicationSupport.appendingPathComponent("Sessions", isDirectory: true)
    }
}
