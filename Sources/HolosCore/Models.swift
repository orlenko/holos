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

/// What made a word fix (`TranscriptWordFix`). Open string code.
public struct TranscriptWordFixKind: OpenStringCode {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// A learned correction (corrections.json), applied as dictation applies it.
    public static let correction = TranscriptWordFixKind("correction")
    /// A word-list term the on-device model chose where one of its "often heard as" phrases was written.
    public static let term = TranscriptWordFixKind("term")
    /// A fix the person explicitly reverted in Review. The mark protects those restored words from automatic
    /// word-fix passes; an explicitly requested `session fix-words` may check them again.
    public static let reviewRevert = TranscriptWordFixKind("reviewRevert")
    /// A correction made against a finalized phrase while its meeting was still recording.
    public static let liveCorrection = TranscriptWordFixKind("liveCorrection")
    /// Words the person typed in Review's edit mode (docs/meeting-design.md §5.10, "Editing words"). `heard` is what
    /// the recognizer wrote over the whole edited span; like a live correction, the edit is in the unfixed base too,
    /// so automatic word fixes never replace it.
    public static let reviewEdit = TranscriptWordFixKind("reviewEdit")
}

/// Words of a segment that the meeting word-fix stage changed (docs/design.md "Meeting word fixes"): what the
/// recognizer wrote there, and what made the change.
public struct TranscriptWordFix: Codable, Sendable, Equatable {
    /// The fixed words: `[first, end)` of the segment's effective words (`WordTiming.effectiveWords`, the index space
    /// of speaker turns).
    public var first: Int
    public var end: Int
    /// The text the recognizer wrote there. For `reviewRevert`, the automatic replacement the person rejected.
    public var heard: String
    public var kind: TranscriptWordFixKind
    /// How many recognizer words `heard` stands for ("你好世界" for two timed words, "hello — there" for two, "type c"
    /// in "“type c”" for two). Recorded on every Review edit and automatic fix written from this version on; nil on
    /// older fixes (and on reverts and live corrections, which occupy their own words), whose count is `heard`'s
    /// whitespace-separated tokens.
    public var heardWords: Int?

    public init(first: Int, end: Int, heard: String, kind: TranscriptWordFixKind, heardWords: Int? = nil) {
        self.first = first; self.end = end; self.heard = heard; self.kind = kind; self.heardWords = heardWords
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
    /// Words changed by the automatic word-fix or live-correction stages; nil when none, so unchanged segments encode
    /// as before. The transcript's lineage says which stage made the revision.
    public var fixes: [TranscriptWordFix]?

    public init(id: String = UUID().uuidString, start: Double, end: Double, text: String,
                words: [TimedWord] = [], track: String? = nil, speakerID: String? = nil, language: String? = nil,
                fixes: [TranscriptWordFix]? = nil) {
        self.id = id; self.start = start; self.end = end; self.text = text
        self.words = words; self.track = track; self.speakerID = speakerID; self.language = language
        self.fixes = fixes
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
    /// For a transcript made by the meeting word-fix stage (docs/design.md "Meeting word fixes"): the revision whose
    /// words it fixed, which is kept. Nil for every other transcript.
    public var fixedFrom: String?
    /// The original revision underlying live text corrections. Kept through automatic word-fix revisions so untimed
    /// words and speaker edits can be mapped in the same stable word space.
    public var liveCorrectedFrom: String?
    /// What recognized the words when it was not Apple's speech recognition (`backend`): "whisper:<model>" for a
    /// transcript made by the deep transcription pass after a meeting (docs/meeting-design.md §4.16), and every
    /// revision made from it (live corrections, word fixes). Nil otherwise, so other transcripts encode as before.
    public var engine: String?

    public init(id: String = UUID().uuidString, createdAt: Date = Date(), source: String,
                locale: String, backend: SpeechBackend, segments: [TranscriptSegment] = [],
                languages: [String]? = nil, fixedFrom: String? = nil, liveCorrectedFrom: String? = nil,
                engine: String? = nil) {
        self.id = id; self.createdAt = createdAt; self.source = source
        self.locale = locale; self.backend = backend; self.segments = segments; self.languages = languages
        self.fixedFrom = fixedFrom; self.liveCorrectedFrom = liveCorrectedFrom; self.engine = engine
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
