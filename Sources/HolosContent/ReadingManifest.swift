import Foundation
import HolosSynthesis

public struct ReadingPart: Codable, Sendable, Equatable {
    public let index: Int
    public let sourceUTF16Offset: Int
    public let sourceUTF16Length: Int
    public let textSHA256: String
    public let relativeAudioPath: String
    /// Starts a chapter with this title.
    public let chapter: String?
    /// Starts a section, so a longer pause comes before it.
    public let startsSection: Bool
    public var status: String
    public var audioSHA256: String?
    public var duration: Double?
}

/// The fixed encoding settings a reading's file is made with. Saved in the manifest so a reading
/// started by another version with different settings is not resumed into a mixed file.
public struct ReadingFormatSettings: Codable, Sendable, Equatable {
    public let fileExtension: String
    public let sampleRate: Double
    public let bitRate: Int
    public let channels: Int
    public let partGap: Double
    public let chapterGap: Double

    public static let current = ReadingFormatSettings(
        fileExtension: ReadingAudioFormat.fileExtension, sampleRate: ReadingAudioFormat.sampleRate,
        bitRate: ReadingAudioFormat.bitRate, channels: ReadingAudioFormat.channels,
        partGap: ReadingAudioFormat.partGap, chapterGap: ReadingAudioFormat.chapterGap)
}

public struct ReadingManifest: Codable, Sendable, Equatable {
    /// 4: explicit-output caches are keyed by `ReadingPipeline.identity`'s JSON hash. A cache of
    /// an earlier version is never resumed (its key is never computed again, and its manifest is
    /// refused as another version's).
    public static let currentSchemaVersion = 4
    /// Marks a manifest this app wrote, so an unrelated `manifest.json` is never taken for one.
    public static let readingKind = "voiceislocal.reading"
    public static let fileName = "manifest.json"

    public let kind: String
    public let schemaVersion: Int
    public let sourceSHA256: String
    /// Everything besides the text and the part plan that ends up in the finished file.
    public let voiceIdentifier: String
    public let rate: Float?
    public let title: String?
    public let author: String?
    public let language: String?
    public let comment: String
    public let format: ReadingFormatSettings
    /// Absolute path of the finished `.m4a`.
    public let output: String
    /// Checksum of the finished file, saved before it is published so a reading interrupted
    /// right after publishing is recognized as done.
    public var outputSHA256: String?
    public var duration: Double?
    public var chapters: [AudioBookChapter]
    public var status: String
    /// The render cache. Part files are deleted once the finished file is published.
    public var parts: [ReadingPart]
    /// The file this reading created at `output` while copying the finished file into it (on
    /// volumes that cannot rename exclusively), saved before any byte is written: a copy cut off
    /// by a crash is recognized on `--resume` as this reading's own partial output.
    public var publishing: ReadingFileIdentity? = nil
    /// The finished file's size, saved with its checksum: a copy that a crash cut off is smaller; a file with the
    /// copy's identity that is as large is the finished file edited in place since, never removed as a partial one.
    public var outputSize: Int64? = nil
    /// The natural voices' model commit the parts were rendered with (`NaturalVoiceModels.revision`); nil for an Apple
    /// voice. A reading is resumed only with the same one, so no file mixes parts of two versions of the voices.
    public var modelRevision: String? = nil
    /// What the renderer rendered the first part with besides voice, text, and speed (a natural voice's fallback
    /// system voice and check policy, `NaturalRenderSettings`), saved when the reading starts and given back for every
    /// part, so a resumed reading does not mix them; nil for a renderer that has none.
    public var rendererSettings: [String: String]? = nil

    /// Manifests are small (under 1 KB per part); a larger `manifest.json` is not read.
    static let maximumBytes = 64 << 20

    /// Whether `url` is a manifest this app wrote (any schema version): it names
    /// `readingKind`. Anything else, including unreadable JSON, is not.
    public static func isReading(_ url: URL) -> Bool {
        struct Marker: Decodable { let kind: String?; let schemaVersion: Int? }
        guard let data = try? readSmallFile(url, maximumBytes: maximumBytes),
              let marker = try? JSONDecoder().decode(Marker.self, from: data) else { return false }
        return marker.kind == readingKind && marker.schemaVersion != nil
    }

    /// Whether this saved reading was made from the same settings: every value that ends up
    /// in the finished file, besides the text and the part plan (which includes chapter titles).
    /// The output compares by exact identity (see `ReadingPathIdentity.Rule.exact`): another
    /// spelling resumes this reading only when it names the same file.
    func sameSettings(voiceIdentifier: String, rate: Float?, metadata: AudioBookMetadata, output: URL,
                      volume: ReadingPathIdentity.VolumeQuery = ReadingPathIdentity.volumeRules) -> Bool {
        self.voiceIdentifier == voiceIdentifier && self.rate == rate
            && modelRevision == ReadingPipeline.modelRevision(for: voiceIdentifier)
            && title == metadata.title && author == metadata.author && language == metadata.language
            && comment == metadata.comment && format == .current
            // Compared byte for byte: Swift's `==` takes NFC and NFD spellings for one string.
            && (self.output.utf8.elementsEqual(output.path.utf8)
                || ReadingPathIdentity.key(path: self.output, .exact, volume: volume).utf8
                    .elementsEqual(ReadingPathIdentity.key(output, .exact, volume: volume).utf8))
    }
}

/// How far a render has got, reported on the main actor as it goes (see `ReadingPipeline.render`).
public enum ReadingRenderProgress: Sendable, Equatable {
    /// Part `part` (counted from 1) of `of` is being rendered. Parts a resumed reading already
    /// has are skipped, so the first report of a resume can be any part.
    case rendering(part: Int, of: Int)
    /// Every part is rendered; they are being joined into the finished file.
    case joining(parts: Int)
}

public struct ReadingResult: Sendable, Equatable {
    public let output: URL
    public let manifest: ReadingManifest
    /// Bookkeeping that failed after the finished file was published (saving the final manifest,
    /// removing the part files): one sentence each, for stderr. The reading itself succeeded.
    public var warnings: [String] = []
    /// The identity of the file this run published at `output` (or, when it had been published before, of the file
    /// found there, read unchanged while its checksum was checked); nil when that could not be told. Not looked up
    /// at `output` afterwards, where another file may have taken its place.
    public var outputIdentity: ReadingFileIdentity? = nil
}
