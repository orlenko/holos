import CryptoKit
import Darwin
import Foundation
import HolosCore
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

@MainActor public protocol ReadingAudioRenderer {
    func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL)
        async throws -> RenderedAudio
    /// Fails unless the renderer can speak with the voice `identifier`. Checked before a reading
    /// creates anything.
    func checkVoice(_ identifier: String) throws
}

extension ReadingAudioRenderer {
    /// A renderer that cannot tell which voices it has accepts every one here; `render` fails
    /// for one it lacks.
    public func checkVoice(_ identifier: String) throws {}
}

extension NativeSpeechRenderer: ReadingAudioRenderer {}
extension NaturalSpeechRenderer: ReadingAudioRenderer {}

/// Reads with a natural voice ("pocket:…", see `NaturalVoiceCatalog`) through `natural`, and with any other voice
/// through `system` (Apple's voices).
@MainActor public final class RoutingSpeechRenderer: ReadingAudioRenderer {
    private let system: any ReadingAudioRenderer
    private let natural: any ReadingAudioRenderer

    public init(system: any ReadingAudioRenderer = NativeSpeechRenderer(), natural: any ReadingAudioRenderer) {
        self.system = system
        self.natural = natural
    }

    private func renderer(for identifier: String?) -> any ReadingAudioRenderer {
        identifier.map(NaturalVoiceCatalog.isNatural) == true ? natural : system
    }

    public func render(text: String, voiceIdentifier: String?, rate: Float?, to output: URL)
        async throws -> RenderedAudio {
        try await renderer(for: voiceIdentifier).render(text: text, voiceIdentifier: voiceIdentifier, rate: rate,
                                                        to: output)
    }

    public func checkVoice(_ identifier: String) throws {
        try renderer(for: identifier).checkVoice(identifier)
    }
}

@MainActor public protocol ReadingAudioJoiner {
    func join(parts: [AudioBookPart], metadata: AudioBookMetadata, to output: URL) async throws -> AudioBookSummary
}

public struct AudioBookJoiner: ReadingAudioJoiner {
    public init() {}
    public func join(parts: [AudioBookPart], metadata: AudioBookMetadata,
                     to output: URL) async throws -> AudioBookSummary {
        try await AudioBookWriter.write(parts: parts, metadata: metadata, to: output)
    }
}

/// Renders a script part by part into a cache of PCM files (so an interrupted reading resumes
/// where it stopped), then joins the parts into one AAC `.m4a` with chapters.
@MainActor public final class ReadingPipeline {
    nonisolated static let partExtension = "caf"
    /// The longest part rendered at once, in UTF-16 units.
    nonisolated public static let defaultMaxPartUTF16Units = 3_000

    private let renderer: any ReadingAudioRenderer
    private let joiner: any ReadingAudioJoiner
    private let exclusiveRename: ReadingPublisher.ExclusiveRename
    /// Called after each step of creating a new reading's cache; tests fail one to check that
    /// nothing is left behind.
    private let initializationFault: @Sendable (ReadingCache.Step) throws -> Void
    /// Called before each manifest save of a render; tests fail one (a full or unwritable cache
    /// volume) to check how the reading copes.
    private let saveFault: @Sendable (ReadingManifest) throws -> Void
    /// Removes a cache's part files; tests fail it.
    private let removeParts: @Sendable (URL) throws -> Void

    public convenience init(renderer: any ReadingAudioRenderer = NativeSpeechRenderer(),
                joiner: any ReadingAudioJoiner = AudioBookJoiner()) {
        self.init(renderer: renderer, joiner: joiner, exclusiveRename: ReadingPublisher.systemExclusiveRename)
    }

    init(renderer: any ReadingAudioRenderer, joiner: any ReadingAudioJoiner,
         exclusiveRename: @escaping ReadingPublisher.ExclusiveRename = ReadingPublisher.systemExclusiveRename,
         initializationFault: @escaping @Sendable (ReadingCache.Step) throws -> Void = { _ in },
         saveFault: @escaping @Sendable (ReadingManifest) throws -> Void = { _ in },
         removeParts: @escaping @Sendable (URL) throws -> Void = { try ReadingPipeline.removeParts(in: $0) }) {
        self.renderer = renderer
        self.joiner = joiner
        self.exclusiveRename = exclusiveRename
        self.initializationFault = initializationFault
        self.saveFault = saveFault
        self.removeParts = removeParts
    }

    /// Everything a reading's cache key covers, encoded as JSON (keys sorted, every string
    /// escaped), so no two sets of values share an encoding whatever characters they hold: a
    /// title "A\u{1}B" without an author and a title "A" by "B" are two readings.
    struct Identity: Encodable {
        struct Segment: Encodable { let chapter: String?; let text: String }
        let kind: String
        let schemaVersion: Int
        let voiceIdentifier: String
        /// As Swift prints it, so a non-finite rate (refused later by `validate`) encodes too.
        let rate: String?
        let title: String?
        let author: String?
        let language: String?
        let comment: String
        let format: ReadingFormatSettings
        let segments: [Segment]
        /// The natural voices' model commit; nil (and left out of the encoding, so the key of a reading with an Apple
        /// voice is what it always was) for an Apple voice.
        var modelRevision: String? = nil

        // Nil values are written as null rather than left out, so each field is always present (but the model
        // revision, written only for a natural voice).
        enum CodingKeys: String, CodingKey {
            case kind, schemaVersion, voiceIdentifier, rate, title, author, language, comment, format, segments
            case modelRevision
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(voiceIdentifier, forKey: .voiceIdentifier)
            try container.encode(rate, forKey: .rate)
            try container.encode(title, forKey: .title)
            try container.encode(author, forKey: .author)
            try container.encode(language, forKey: .language)
            try container.encode(comment, forKey: .comment)
            try container.encode(format, forKey: .format)
            try container.encode(segments, forKey: .segments)
            if let modelRevision { try container.encode(modelRevision, forKey: .modelRevision) }
        }
    }

    /// The model commit a reading with `voiceIdentifier` is rendered with: `NaturalVoiceModels.revision` for a natural
    /// voice, nil for an Apple voice.
    nonisolated public static func modelRevision(for voiceIdentifier: String) -> String? {
        NaturalVoiceCatalog.isNatural(voiceIdentifier) ? NaturalVoiceModels.revision : nil
    }

    /// The cache key for a reading with an explicit output: the text and every setting that
    /// ends up in the finished file, so a change to any of them starts a new reading. A SHA-256
    /// of `Identity`'s JSON, in lowercase hex. The key format is part of the manifest's schema
    /// version (so a cache keyed another way is never looked for: it is stale, like one whose
    /// settings changed).
    nonisolated public static func identity(script: ReadingScript, voiceIdentifier: String, rate: Float?,
                                metadata: AudioBookMetadata) -> String {
        let identity = Identity(
            kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
            voiceIdentifier: voiceIdentifier, rate: rate.map { "\($0)" }, title: metadata.title, author: metadata.author,
            language: metadata.language, comment: metadata.comment, format: .current,
            segments: script.segments.map { Identity.Segment(chapter: $0.chapter, text: $0.text) },
            modelRevision: modelRevision(for: voiceIdentifier))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Only strings, integers, and the format's finite constants are encoded: this cannot fail.
        guard let data = try? encoder.encode(identity) else { preconditionFailure("Reading identity did not encode.") }
        return sha256(data)
    }

    public func render(script: ReadingScript, voiceIdentifier: String, rate: Float? = nil,
                       metadata: AudioBookMetadata, location: ReadingLocation,
                       resume: Bool = false,
                       maxPartUTF16Units: Int = defaultMaxPartUTF16Units,
                       progress: ((ReadingRenderProgress) -> Void)? = nil) async throws -> ReadingResult {
        let directory = location.workDirectory
        let output = location.output
        // Every setting is checked before anything (lock, cache, source, manifest) is created, so
        // a bad one never leaves a cache behind that cannot be resumed.
        try validateSettings(script: script, voiceIdentifier: voiceIdentifier, rate: rate, metadata: metadata,
                             location: location)
        // Planned off the main actor: a book is split into hundreds of parts, each hashed.
        let (planned, expected) = try await offMain { () -> ([ReadingScript.Part], [ReadingPart]) in
            let planned = script.parts(maxUTF16Units: maxPartUTF16Units)
            let expected = planned.map { part in
                ReadingPart(index: part.index, sourceUTF16Offset: part.offset, sourceUTF16Length: part.length,
                            textSHA256: sha256(Data(part.text.utf8)),
                            relativeAudioPath: Self.partPath(part.index),
                            chapter: part.chapter, startsSection: part.startsSegment, status: "pending")
            }
            return (planned, expected)
        }
        try Task.checkCancellation()
        let manifestURL = directory.appendingPathComponent(ReadingManifest.fileName)
        // This run's name for the joined file.
        let run = UUID()
        // The locations are checked, the lock and the reservation taken, and the cache made or its manifest read,
        // off the main actor: the output folder may be on a slow share. The lock and the reservation are held until
        // this render returns.
        let (text, fault) = (script.text, initializationFault)
        let prepared = try await offMain {
            try Self.prepare(directory: directory, output: output, resume: resume, text: text, expected: expected,
                             voiceIdentifier: voiceIdentifier, rate: rate, metadata: metadata, run: run, fault: fault)
        }
        // The joined file's name for this run: the joiner makes it, and it goes on every exit, cancellation (Ctrl-C in
        // `voiceislocal read`) included. The name carries this run's UUID, so nothing but this run's joiner makes a
        // file there.
        let temporary = ReadingTemporaries.joinURL(beside: output, key: prepared.key, run: run)
        do {
            let result = try await renderPrepared(
                prepared, planned: planned, voiceIdentifier: voiceIdentifier, rate: rate, metadata: metadata,
                location: location, manifestURL: manifestURL, temporary: temporary, progress: progress)
            await Self.release(prepared, temporary: temporary)
            return result
        } catch {
            await Self.release(prepared, temporary: temporary)
            throw error
        }
    }

    /// The end of a render, off the main actor (the output folder may be on a slow share): this run's joined file
    /// removed, and the output's reservation released (the cache's lock goes with `prepared`).
    nonisolated private static func release(_ prepared: Prepared, temporary: URL) async {
        _ = try? await offMain {
            _ = unlink(RawFilePath.system(temporary))
            prepared.held.1?.release()
        }
    }

    /// The render once `prepare` has run: parts rendered (those a resume finds still good kept), joined into
    /// `temporary`, and published at the output.
    private func renderPrepared(_ prepared: Prepared, planned: [ReadingScript.Part], voiceIdentifier: String,
                                rate: Float?, metadata: AudioBookMetadata, location: ReadingLocation,
                                manifestURL: URL, temporary: URL,
                                progress: ((ReadingRenderProgress) -> Void)?) async throws -> ReadingResult {
        let directory = location.workDirectory
        let output = location.output
        try Task.checkCancellation()
        var manifest = prepared.manifest
        let key = prepared.key

        // Finished before (possibly interrupted right after publishing): nothing to do. Checked off the main actor
        // (the whole file is read), and a Stop meanwhile ends the run here rather than report it made.
        if let published = manifest.outputSHA256 {
            let found = try await offMain { () -> (matches: Bool, identity: ReadingFileIdentity?) in
                // The file checked is the file at the output only when it is the same file before and after the
                // check: one replaced or removed meanwhile (a sync client) is not taken for the reading made.
                guard let before = ExclusivePublisher.FileIdentity.of(output),
                      (try? fileSHA256(output)) == published,
                      ExclusivePublisher.FileIdentity.of(output) == before else { return (false, nil) }
                return (true, before)
            }
            try Task.checkCancellation()
            if found.matches {
                return try await finishOffMain(manifest, manifestURL: manifestURL, directory: directory,
                                               output: output, identity: found.identity)
            }
        }
        // A copy into the destination that a crash cut off is this reading's own file: it goes,
        // and the reading is joined and published again. Anything else there is kept. Its removal goes through a
        // place aside derived from the reading (`ReadingTemporaries.publicationToken`), where one a crash cut off is
        // found first; the manifest keeps the copy's identity until both are gone.
        let token = ReadingTemporaries.publicationToken(key: key)
        let claimed = manifest.publishing
        let evidence = ReadingLibrary.Evidence(checksums: [], publishing: claimed, finishedSize: manifest.outputSize)
        let problem = try await offMain { () -> String? in
            try ReadingTemporaries.recoverPublicationAside(output: output, key: key, evidence: evidence)
            // The copy's file, as large as the finished one, is the finished file edited in place since (a crash came
            // after the copy was done and before it was recorded): it is kept, and so is its identity.
            if let claimed, try ReadingLibrary.FileVersion.of(output)?.identity == claimed, try !evidence.isPartial(output) {
                throw HolosError.io("A file is at \(output.path) that may be this reading's, finished and changed "
                    + "since; it is left there. Move it away or remove it, then try again.")
            }
            let problem = claimed.flatMap { ReadingLibrary.removePartial(output, identity: $0, token: token).problem }
            // Nothing found proves nothing where the folder cannot be reached (its drive went away since the start).
            try Self.checkReachable(output)
            return problem
        }
        if let problem { throw HolosError.io(problem) }
        if claimed != nil {
            manifest.publishing = nil
            try await saveManifest(manifest, to: manifestURL)
        }
        try Task.checkCancellation()
        try await offMain {
            guard try !ReadingOutput.exists(output) else {
                throw HolosError.invalidInput("Reading output already exists and is not this reading: \(output.path)")
            }
            // The finished file's checksum is forgotten next: only while its folder can be looked into.
            try Self.checkReachable(output)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("parts"),
                                                    withIntermediateDirectories: true)
        }
        manifest.status = "incomplete"
        manifest.outputSHA256 = nil
        manifest.outputSize = nil
        manifest.duration = nil
        manifest.chapters = []

        // Only parts whose files still match their checksums are reused.
        for index in manifest.parts.indices {
            // Each check reads a part off the main actor; a Stop meanwhile ends the resume here.
            try Task.checkCancellation()
            let part = manifest.parts[index]
            let audio = directory.appendingPathComponent(part.relativeAudioPath)
            var valid = false
            if part.status == "complete", let expected = part.audioSHA256 {
                valid = (try? await fileSHA256OffMain(audio)) == expected
                // A Stop during the check never marks the part for rendering again.
                try Task.checkCancellation()
            }
            if !valid {
                manifest.parts[index].status = "pending"
                manifest.parts[index].audioSHA256 = nil
                manifest.parts[index].duration = nil
            }
        }
        try await saveManifest(manifest, to: manifestURL)

        for part in planned {
            try Task.checkCancellation()
            if manifest.parts[part.index].status == "complete" { continue }
            progress?(.rendering(part: part.index + 1, of: planned.count))
            let audio = directory.appendingPathComponent(manifest.parts[part.index].relativeAudioPath)
            try await offMain {
                if FileManager.default.fileExists(atPath: audio.path) {
                    let quarantined = audio.deletingLastPathComponent()
                        .appendingPathComponent(".invalid-\(UUID().uuidString)-\(audio.lastPathComponent)")
                    try FileManager.default.moveItem(at: audio, to: quarantined)
                }
            }
            do {
                let result = try await renderer.render(text: part.text, voiceIdentifier: voiceIdentifier,
                                                       rate: rate, to: audio)
                guard result.url.standardizedFileURL == audio.standardizedFileURL else {
                    throw HolosError.io("Speech renderer returned an unexpected part path.")
                }
                manifest.parts[part.index].status = "complete"
                manifest.parts[part.index].audioSHA256 = try await fileSHA256OffMain(result.url)
                manifest.parts[part.index].duration = result.duration
                try await saveManifest(manifest, to: manifestURL)
            } catch {
                manifest.status = "incomplete"
                try? await saveManifest(manifest, to: manifestURL)
                throw HolosError.incomplete("Reading stopped at part \(part.index + 1) of \(planned.count): \(error.localizedDescription)")
            }
        }

        try Task.checkCancellation()
        let audioParts = manifest.parts.map { part in
            AudioBookPart(url: directory.appendingPathComponent(part.relativeAudioPath),
                          silenceBefore: part.index == 0 ? 0
                              : part.startsSection ? ReadingAudioFormat.chapterGap : ReadingAudioFormat.partGap,
                          chapter: part.chapter)
        }
        let summary: AudioBookSummary
        progress?(.joining(parts: planned.count))
        do {
            summary = try await joiner.join(parts: audioParts, metadata: metadata, to: temporary)
        } catch {
            try? await saveManifest(manifest, to: manifestURL)
            throw HolosError.incomplete("Reading parts are rendered, but joining them failed: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        manifest.outputSHA256 = try await fileSHA256OffMain(temporary)
        manifest.outputSize = try await offMain { () -> Int64? in
            var metadata = stat()
            return lstat(RawFilePath.system(temporary), &metadata) == 0 ? Int64(metadata.st_size) : nil
        }
        manifest.duration = summary.duration
        manifest.chapters = summary.chapters
        try await saveManifest(manifest, to: manifestURL)
        try Task.checkCancellation()
        // Published off the main actor: on a volume that cannot rename exclusively the whole file is copied and
        // flushed, which on a slow drive takes long enough to freeze the app. The manifest saves the copy's identity
        // there, before any byte is written; a Stop reaches the copy between its chunks.
        let (saveFault, rename) = (self.saveFault, exclusiveRename)
        let claiming = manifest
        let outcome = try await offMain { () -> Publication in
            var saved = claiming
            var claimedIdentity: ReadingFileIdentity?
            // The file published: the joined file itself when it is renamed into place (a rename keeps its
            // identity), or the copy made into place.
            var published = ExclusivePublisher.FileIdentity.of(temporary)
            do {
                try ReadingPublisher.publish(temporary, to: output, exclusiveRename: rename, cleanupToken: token) { claimed in
                    published = claimed
                    claimedIdentity = claimed
                    saved.publishing = claimed
                    try saveFault(saved)
                    try save(saved, to: manifestURL)
                }
            } catch let failure as ExclusivePublisher.CleanupFailed {
                return .failed(failure, keep: failure.identity)
            } catch {
                // A copy begun whose removal found nothing where the folder cannot be reached (its drive or share went
                // away meanwhile) may be there once it is back: its identity is kept.
                let unconfirmed = claimedIdentity != nil && ReadingOutput.unreachableReason(for: output) != nil
                return .failed(error, keep: unconfirmed ? claimedIdentity : nil)
            }
            return .published(published, claimed: claimedIdentity)
        }
        switch outcome {
        case .failed(let error, let keep):
            // A copy that may still be there (or aside) keeps its identity saved, so a resume or a Delete finds it,
            // and the finished size and checksum: a copy that got to its end (its flush or close failed) is then
            // recognized as the finished file.
            manifest.publishing = keep
            if keep == nil {
                manifest.outputSHA256 = nil
                manifest.outputSize = nil
            }
            try? await saveManifest(manifest, to: manifestURL)
            throw error
        case .published(let published, let claimed):
            manifest.publishing = claimed
            return try await finishOffMain(manifest, manifestURL: manifestURL, directory: directory, output: output,
                                           identity: published)
        }
    }

    /// How the publication of the finished file went: published (the file's identity, and the copy's, when it was
    /// copied into place), or failed, keeping the identity of a copy that may still be there.
    enum Publication: @unchecked Sendable {
        case published(ReadingFileIdentity?, claimed: ReadingFileIdentity?)
        case failed(any Error, keep: ReadingFileIdentity?)
    }

    /// Fails when the folder that holds `output` cannot be reached (see `ReadingOutput.unreachableReason`): a file not
    /// found there may be there once it is back.
    nonisolated static func checkReachable(_ output: URL) throws {
        if let reason = ReadingOutput.unreachableReason(for: output) {
            throw HolosError.unavailable("\(output.lastPathComponent) is unavailable: \(reason). Connect it, then try "
                + "again.")
        }
    }

    /// What `prepare` leaves the render: the lock and the reservation it holds, the manifest, and the reading's key.
    struct Prepared: Sendable {
        let held: (ReadingDirectoryLock, ReadingOutputReservation?)
        let manifest: ReadingManifest
        let key: String
    }

    /// The start of a render, off the main actor: the locations checked (see `checkLocation`), the cache's lock and
    /// the output's reservation taken, caches that runs killed while creating them removed, and then, for a resume,
    /// the saved manifest read and checked against the text and settings, or, for a new reading, the cache made (see
    /// `ReadingCache.create`). Temporaries an interrupted earlier run left behind (killed before its cleanup ran)
    /// are removed last: the lock means no other run of this reading is active, and only names this reading's runs
    /// create are touched.
    nonisolated static func prepare(directory: URL, output: URL, resume: Bool, text: String, expected: [ReadingPart],
                                    voiceIdentifier: String, rate: Float?, metadata: AudioBookMetadata, run: UUID,
                                    fault: (ReadingCache.Step) throws -> Void) throws -> Prepared {
        try checkLocation(directory: directory, output: output, resume: resume)
        let writerLock = try ReadingDirectoryLock.acquire(for: directory)
        // An output inside its cache (a reading without `--output`) is reserved in the cache,
        // beside it: when resuming, now; for a new reading, once the cache is in place.
        let outputInCache = output.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path
        var reservation = try outputInCache && !(resume && ReadingOutput.exists(directory))
            ? nil : try ReadingOutputReservation.acquire(output: output)
        // Caches that runs killed while creating them left behind (see `ReadingCache.create`).
        ReadingCache.sweep(beside: directory)
        let sourceHash = sha256(Data(text.utf8))
        let sourceURL = directory.appendingPathComponent("source.txt")
        let manifestURL = directory.appendingPathComponent(ReadingManifest.fileName)
        let manifest: ReadingManifest
        if resume {
            guard try ReadingOutput.exists(directory) else {
                throw HolosError.invalidInput("No reading exists to resume at \(directory.path).")
            }
            guard ReadingManifest.isReading(manifestURL) else {
                throw HolosError.invalidInput("No Voice is Local reading to resume at \(directory.path).")
            }
            guard let saved = try? JSONDecoder().decode(
                      ReadingManifest.self, from: readSmallFile(manifestURL, maximumBytes: ReadingManifest.maximumBytes)),
                  saved.schemaVersion == ReadingManifest.currentSchemaVersion else {
                throw HolosError.invalidInput("The reading at \(directory.path) was made by another version and cannot be resumed.")
            }
            manifest = saved
            let savedSource = try? fileSHA256(sourceURL)
            // A Stop during the check is a stop, never "the source differs".
            if Task.isCancelled { throw CancellationError() }
            if manifest.voiceIdentifier == voiceIdentifier,
               manifest.modelRevision != modelRevision(for: voiceIdentifier) {
                throw HolosError.invalidInput("This reading was started with another version of the natural voices "
                    + "(\(manifest.modelRevision ?? "unknown")); its parts cannot be joined with ones the current voices "
                    + "make. Delete it and make it again.")
            }
            guard manifest.sourceSHA256 == sourceHash,
                  manifest.sameSettings(voiceIdentifier: voiceIdentifier, rate: rate, metadata: metadata, output: output),
                  savedSource == sourceHash else {
                throw HolosError.invalidInput("Reading source, voice, rate, title, author, language, or output differs from the saved reading.")
            }
            guard manifest.parts.count == expected.count,
                  zip(manifest.parts, expected).allSatisfy({ samePlan($0, $1) }) else {
                throw HolosError.invalidInput("Reading part boundaries differ from the saved reading.")
            }
        } else {
            // A cache an earlier version left half made, with no manifest, goes, and the
            // locations are checked as for a new reading (`checkLocation` skipped them while it was there).
            if ReadingCache.removeAbandoned(directory) {
                try checkLocation(directory: directory, output: output, resume: false)
            }
            guard try !ReadingOutput.exists(directory) else {
                throw HolosError.invalidInput("A reading already exists at \(directory.path). Use --resume to continue it.")
            }
            // Looked up as spelled (`FileManager` would decompose it; see `RawFilePath`).
            guard try !ReadingOutput.exists(output) else {
                throw HolosError.invalidInput("Reading output already exists: \(output.path)")
            }
            manifest = ReadingManifest(kind: ReadingManifest.readingKind,
                                       schemaVersion: ReadingManifest.currentSchemaVersion,
                                       sourceSHA256: sourceHash, voiceIdentifier: voiceIdentifier, rate: rate,
                                       title: metadata.title, author: metadata.author, language: metadata.language,
                                       comment: metadata.comment, format: .current, output: output.path,
                                       outputSHA256: nil, duration: nil, chapters: [],
                                       status: "incomplete", parts: expected,
                                       modelRevision: modelRevision(for: voiceIdentifier))
            try ReadingCache.create(directory, source: Data(text.utf8), manifest: manifest, fault: fault)
            if reservation == nil { reservation = try ReadingOutputReservation.acquire(output: output) }
        }
        let key = ReadingTemporaries.key(for: directory)
        ReadingTemporaries.sweep(workDirectory: directory, outputFolder: output.deletingLastPathComponent(),
                                 key: key, currentRun: run)
        return Prepared(held: (writerLock, reservation), manifest: manifest, key: key)
    }

    /// `finish` off the main actor (removing the part files of a long reading takes a while on a slow drive).
    private func finishOffMain(_ manifest: ReadingManifest, manifestURL: URL, directory: URL, output: URL,
                               identity: ReadingFileIdentity?) async throws -> ReadingResult {
        let (saveFault, removeParts) = (self.saveFault, self.removeParts)
        return try await offMain {
            Self.finish(manifest, manifestURL: manifestURL, directory: directory, output: output, identity: identity,
                        saveFault: saveFault, removeParts: removeParts)
        }
    }

    /// The bookkeeping once the finished file is at `output`: the manifest marked complete and
    /// the part files removed. The reading has succeeded by then, so neither can fail it; a step
    /// that fails is reported as a warning. The manifest saved before publishing already holds
    /// the file's checksum, so a `--resume` recognizes the reading as done either way.
    nonisolated private static func finish(_ manifest: ReadingManifest, manifestURL: URL, directory: URL,
                                           output: URL, identity: ReadingFileIdentity?,
                                           saveFault: (ReadingManifest) throws -> Void,
                                           removeParts: (URL) throws -> Void) -> ReadingResult {
        var manifest = manifest
        var warnings: [String] = []
        if manifest.status != "complete" || manifest.publishing != nil {
            manifest.status = "complete"
            manifest.publishing = nil
            do {
                try saveFault(manifest)
                try save(manifest, to: manifestURL)
            } catch {
                warnings.append("The reading was saved to \(output.path), but its cache at \(directory.path) could not be marked complete: \(error.localizedDescription)")
            }
        }
        do {
            try removeParts(directory)
        } catch {
            warnings.append("The reading was saved to \(output.path), but its part files in \(directory.path) could not be removed: \(error.localizedDescription)")
        }
        return ReadingResult(output: output, manifest: manifest, warnings: warnings, outputIdentity: identity)
    }

    /// Saves the manifest off the main actor (the cache may be on a slow drive), in the order the render asks.
    private func saveManifest(_ manifest: ReadingManifest, to url: URL) async throws {
        let saveFault = self.saveFault
        try await offMain {
            try saveFault(manifest)
            try save(manifest, to: url)
        }
    }

    /// Fails unless every setting of a reading is usable, creating nothing: the text is not
    /// empty; the rate is nil or a finite rate `AVSpeechUtterance` takes (see `SpeechRate`); the
    /// renderer has the voice; a title has readable text (see `AudioBookMetadata.usableTitle`);
    /// the locations are file URLs, the output a `.m4a`. Whether both folders can take their files
    /// (see `checkLocation`) is checked next, off the main actor (see `prepare`).
    func validateSettings(script: ReadingScript, voiceIdentifier: String, rate: Float?, metadata: AudioBookMetadata,
                          location: ReadingLocation) throws {
        let directory = location.workDirectory
        let output = location.output
        guard directory.isFileURL, output.isFileURL else {
            throw HolosError.invalidInput("Reading locations must be file URLs.")
        }
        guard output.pathExtension.lowercased() == ReadingAudioFormat.fileExtension else {
            throw HolosError.invalidInput("Reading output must be a .\(ReadingAudioFormat.fileExtension) file: \(output.path)")
        }
        guard !script.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HolosError.invalidInput("Reading source is empty.")
        }
        try SpeechRate.validate(rate)
        try renderer.checkVoice(voiceIdentifier)
        if let title = metadata.title, AudioBookMetadata.usableTitle(title) == nil {
            throw HolosError.invalidInput("Reading title has no readable text.")
        }
    }

    /// Checks both folders before anything is rendered, so a destination that cannot take the
    /// finished file fails now rather than after hours of rendering: the cache's parent folder
    /// (where the cache and its lock are created) and the output's (see
    /// `ReadingOutput.checkDestination`). An output inside a cache that does not exist yet
    /// (a reading without `--output`) is checked through the cache's parent.
    nonisolated static func checkLocation(directory: URL, output: URL, resume: Bool) throws {
        let cacheExists = try ReadingOutput.exists(directory)
        // A new reading over an existing cache, or a resume without one, fails next with a
        // clearer message ("use --resume", "no reading to resume").
        if cacheExists != resume { return }
        if !cacheExists {
            try ReadingOutput.checkFolder(directory.deletingLastPathComponent(), role: "Reading cache folder",
                                          names: ReadingOutput.cacheFolderNameLength)
        }
        let folder = output.deletingLastPathComponent()
        if !cacheExists && folder.standardizedFileURL.path == directory.standardizedFileURL.path {
            guard ReadingOutput.fits(output.lastPathComponent,
                                     limit: ReadingOutput.nameLimit(in: directory.deletingLastPathComponent())) else {
                throw HolosError.invalidInput("Output file name is too long for its volume: \(output.lastPathComponent)")
            }
            try ReadingOutput.checkPathLength(output)
        } else {
            try ReadingOutput.checkDestination(output, allowExisting: resume)
        }
    }

    nonisolated static func partPath(_ index: Int) -> String {
        String(format: "parts/part%04d.%@", index + 1, partExtension)
    }

    nonisolated private static func samePlan(_ saved: ReadingPart, _ planned: ReadingPart) -> Bool {
        saved.index == planned.index && saved.sourceUTF16Offset == planned.sourceUTF16Offset &&
            saved.sourceUTF16Length == planned.sourceUTF16Length && saved.textSHA256 == planned.textSHA256 &&
            saved.relativeAudioPath == planned.relativeAudioPath && saved.chapter == planned.chapter &&
            saved.startsSection == planned.startsSection
    }

    /// The cache is several times larger than the finished file; it is not kept once that exists.
    /// Already gone is not a failure.
    nonisolated static func removeParts(in directory: URL) throws {
        let parts = directory.appendingPathComponent("parts")
        do {
            try FileManager.default.removeItem(at: parts)
        } catch {
            var metadata = stat()
            guard lstat(parts.path, &metadata) != 0, errno == ENOENT else { throw error }
        }
    }
}

/// Publishes a finished reading through `ExclusivePublisher`, the one helper every file of a
/// reading (each rendered part, the finished `.m4a`) is published with: never over a file that
/// is already there, and without needing hard links.
enum ReadingPublisher {
    typealias ExclusiveRename = ExclusivePublisher.ExclusiveRename

    static let systemExclusiveRename: ExclusiveRename = ExclusivePublisher.systemExclusiveRename

    /// See `ExclusivePublisher.publish`.
    static func publish(_ source: URL, to destination: URL,
                        exclusiveRename: ExclusiveRename = systemExclusiveRename, cleanupToken: String? = nil,
                        claimed: (ReadingFileIdentity) throws -> Void = { _ in }) throws {
        try ExclusivePublisher.publish(source, to: destination, exclusiveRename: exclusiveRename,
                                       existing: "Reading output already exists and is not this reading",
                                       cleanupToken: cleanupToken, claimed: claimed)
    }
}

/// A sibling lock serializes new renders and resumes of one cache across processes: `flock` on a
/// hidden file in the cache's parent (the support folder). The file is intentionally kept so
/// another process cannot lock a replacement inode. An explicit output is reserved separately,
/// beside the destination (see `ReadingOutputReservation`).
final class ReadingDirectoryLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// A hash of the directory's filesystem identity (see `ReadingPathIdentity`).
    static func key(for directory: URL) -> String {
        sha256(Data(ReadingPathIdentity.key(directory).utf8))
    }

    /// `.holos-reading-<key>.lock`, in the cache's parent.
    static func lockName(key: String) -> String { ".holos-reading-\(key).lock" }

    static func acquire(for directory: URL) throws -> ReadingDirectoryLock {
        try acquire(name: lockName(key: key(for: directory)), beside: directory,
                    busy: "Reading directory is already being rendered: \(directory.path)")
    }

    /// Takes the place of `flock(descriptor, LOCK_EX | LOCK_NB)` on the lock file at `path` (tests).
    @TaskLocal static var lockCall: (@Sendable (_ path: String, _ descriptor: Int32) -> Int32)? = nil

    /// The folder a cache's locks are kept in: the cache's parent, links resolved.
    static func folder(beside directory: URL) -> URL {
        directory.standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
    }

    /// The lock of the cache whose `key` is given, in `folder`, when no run holds it; else nil.
    static func acquireIfIdle(key: String, in folder: URL) -> ReadingDirectoryLock? {
        try? acquire(name: lockName(key: key), in: folder, busy: "")
    }

    private static func acquire(name: String, beside directory: URL, busy: String) throws -> ReadingDirectoryLock {
        try acquire(name: name, in: folder(beside: directory), busy: busy)
    }

    /// Opens (creating if needed) and locks `name` in `parent`.
    private static func acquire(name: String, in parent: URL, busy: String) throws -> ReadingDirectoryLock {
        let path = parent.appendingPathComponent(name).path
        var descriptor = open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        if descriptor < 0 && errno == EEXIST {
            descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        }
        guard descriptor >= 0 else {
            throw HolosError.io("Could not open reading lock: \(String(cString: strerror(errno)))")
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
              (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            close(descriptor)
            throw HolosError.io("Reading lock is not a regular file owned by this user.")
        }
        guard (lockCall?(path, descriptor) ?? flock(descriptor, LOCK_EX | LOCK_NB)) == 0 else {
            let error = errno
            close(descriptor)
            if error == EWOULDBLOCK || error == EAGAIN {
                throw HolosError.unavailable(busy)
            }
            throw HolosError.io("Could not acquire reading lock: \(String(cString: strerror(error)))")
        }
        return ReadingDirectoryLock(descriptor: descriptor)
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// The reservation of a reading's output: a hidden file beside the destination that names the
/// process making it. Readings of different text or settings for one output have different
/// caches (see `ReadingOutput.locate`), possibly under different support folders
/// (`HOLOS_SUPPORT_DIR`) or users, so this is what stops a second one before it renders anything.
/// The destination's folder is the one place every producer of that file finds. The reservation
/// needs neither `flock` on the destination's volume nor that the next producer be the same user:
/// - it is created with `O_CREAT | O_EXCL`, mode 0644, and holds a `Record` (host name, the Mac's
///   hardware UUID, process ID and start time, user ID, creation time), so any user can read who
///   holds it;
/// - an existing one is held while its process runs: on this Mac (the same hardware UUID; two
///   Macs can share a host name), a process with its ID and the same start time (a reused ID has
///   another). One whose process has ended (a run killed before its release) is removed and
///   taken, whoever owns it, under a takeover guard (see `takeOver`), so of two runs taking it
///   over at once exactly one goes on. One from another Mac (a shared network folder), or with no
///   hardware UUID, cannot be checked, one that cannot be read or decoded (a run
///   killed between creating and writing it) is not trusted, and one that cannot be removed
///   (another user's file in a sticky shared folder) stays: each is refused with a message
///   naming the file and who can delete it;
/// - it is removed on release when it still holds this run's record.
/// It is named from the file's conservative identity (see `ReadingPathIdentity.Rule.lock`), so
/// "Book.m4a" and "book.m4a" on a case-insensitive volume, or one name in NFC and NFD, share it.
/// Its name and its guard's are among the names `ReadingOutput` checks against the volume's
/// limits before anything is rendered (see `ReadingOutput.outputFolderNameLength`). Its path is
/// the destination folder as spelled (see `RawFilePath`). A reading without `--output` holds one
/// in its cache, beside its `.m4a`.
final class ReadingOutputReservation: @unchecked Sendable {
    struct Record: Codable, Equatable {
        /// `gethostname`, for messages: two Macs can share a host name.
        var host: String
        var pid: Int32
        /// The process's start time, microseconds since 1970 (see `processStart`).
        var start: Int64
        var uid: UInt32
        /// Seconds since 1970.
        var created: Double
        /// The Mac's hardware UUID (see `machineID`), which decides whether the process can be
        /// checked here; empty when it could not be read.
        var machine: String = ReadingOutputReservation.machineID

        /// This process's record, created now.
        static func current() -> Record {
            let pid = getpid()
            return Record(host: hostName(), pid: pid, start: processStart(pid) ?? 0, uid: getuid(),
                          created: Date().timeIntervalSince1970)
        }
    }

    /// A record is well under this; a larger file is not a reservation.
    static let maximumBytes = 4_096

    let path: String
    let record: Record

    private init(path: String, record: Record) {
        self.path = path
        self.record = record
    }

    /// `.holos-output-<first 32 hex digits of the identity's hash>.lock`.
    static func name(for output: URL) -> String {
        name(hash: sha256(Data(ReadingPathIdentity.key(output).utf8)))
    }

    private static func name(hash: String) -> String { ".holos-output-\(hash.prefix(32)).lock" }

    static let guardSuffix = ".takeover"

    /// The longest name a reservation writes beside the output: its guard's.
    static let longestNameLength = (name(hash: String(repeating: "0", count: 32)) + guardSuffix).utf8.count

    /// The reservation for `output`. A reading without `--output` takes one too, in its cache
    /// (once that exists), so a run given that cache's `.m4a` as its `--output` is refused while
    /// it renders.
    static func acquire(output: URL) throws -> ReadingOutputReservation {
        // The folder as spelled, links resolved (see `RawFilePath`).
        let folder = RawFilePath.resolvingFolder(of: output).deletingLastPathComponent()
        return try acquire(path: RawFilePath.appending(name(for: output), to: folder).path, output: output)
    }

    /// The takeover guard of the reservation at `path` (see `takeOver`).
    static func guardPath(for path: String) -> String { path + guardSuffix }

    /// Where a takeover may be interleaved with another run's, for tests: `found` after a stale
    /// reservation is read and before its guard is taken, `verified` under the guard after the
    /// reservation is checked again and before it is removed.
    enum TakeoverStep: Sendable { case found, verified }

    /// Runs at each `TakeoverStep` (tests).
    @TaskLocal static var takeoverStep: (@Sendable (TakeoverStep) -> Void)? = nil

    /// Creates the reservation at `path` for `output`, taking over one whose process has ended.
    static func acquire(path: String, output: URL) throws -> ReadingOutputReservation {
        let mine = Record.current()
        // A retry follows a holder's release, or a takeover that found the reservation changed.
        for _ in 0..<3 {
            if let made = try create(mine, at: path, output: output) { return made }
            switch holder(at: path) {
            case .gone:
                continue
            case .unreadable(let reason):
                throw HolosError.unavailable("Another reading may be under way for \(output.path): its reservation \(path) \(reason). If no reading of that file is running, delete \(path).")
            case .running(let record):
                throw HolosError.unavailable("Another reading is already being made for \(output.path): process \(record.pid) of \(userName(record.uid)), since \(date(record.created)). Its reservation is \(path).")
            case .otherHost(let record):
                throw HolosError.unavailable("Another reading is already being made for \(output.path) on \(computer(record)) (process \(record.pid) of user ID \(record.uid), since \(date(record.created))), which cannot be checked from here. If no reading of that file is running there, delete \(path).")
            case .ended(let record, let owner, let file):
                takeoverStep?(.found)
                if let made = try takeOver(path: path, stale: record, owner: owner, file: file, mine: mine,
                                           output: output) {
                    return made
                }
            }
        }
        throw HolosError.unavailable("Another reading is already being made for \(output.path). Its reservation is \(path).")
    }

    /// Creates the reservation at `path` holding `record`; nil when a file is already there.
    private static func create(_ record: Record, at path: String, output: URL) throws -> ReadingOutputReservation? {
        let descriptor = open(RawFilePath.system(path), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else {
            let error = errno
            guard error == EEXIST else {
                throw HolosError.io("Could not reserve \(output.path) with \(path): \(String(cString: strerror(error)))")
            }
            return nil
        }
        try write(record, to: descriptor, path: path, output: output)
        return ReadingOutputReservation(path: path, record: record)
    }

    /// Replaces the reservation at `path`, the file `file` holding `stale` (made by a process
    /// that has ended), with this run's (`mine`); nil when the reservation changed since it was
    /// read, for the caller to read again.
    ///
    /// Checking that `path` is still that file and removing it are two steps, and between them
    /// another run could replace it, so both happen only while holding the reservation's takeover
    /// guard (`guardPath(for:)`): a file created with `O_CREAT | O_EXCL`, holding this run's
    /// record, and removed once this run's reservation is in place. Only a guard holder removes
    /// a reservation it did not make, so the file checked under the guard is the file removed; a
    /// run that finds the guard held is refused (see `takeGuard`); and a run that read the same
    /// stale reservation but takes the guard later finds this run's reservation instead and does
    /// not touch it.
    private static func takeOver(path: String, stale: Record, owner: uid_t, file: (device: dev_t, inode: ino_t),
                                 mine: Record, output: URL) throws -> ReadingOutputReservation? {
        let guardPath = guardPath(for: path)
        try takeGuard(guardPath, reservation: path, stale: stale, owner: owner, mine: mine, output: output)
        defer { removeIfHolding(guardPath, mine) }
        guard case .ended(let current, _, let still) = holder(at: path), current == stale,
              still.device == file.device, still.inode == file.inode else { return nil }
        takeoverStep?(.verified)
        guard unlink(RawFilePath.system(path)) == 0 || errno == ENOENT else {
            let reason = String(cString: strerror(errno))
            throw HolosError.unavailable("A reading for \(output.path) that is no longer running (process \(stale.pid) of \(userName(stale.uid))) left its reservation \(path), and it cannot be removed here: \(reason). \(userName(owner).capitalizedFirst), who owns it, or an administrator can delete it.")
        }
        return try create(mine, at: path, output: output)
    }

    /// Creates the takeover guard at `guardPath` holding `mine`, or refuses, naming the
    /// reservation and its guard, while another run holds it. A guard is never removed by a run
    /// that did not make it, so there is no check-then-remove step for two runs to interleave in.
    /// One whose run has ended (killed during its takeover, a few system calls long) is refused
    /// like one that cannot be read: the message names the file to delete once no reading of the
    /// output runs.
    private static func takeGuard(_ guardPath: String, reservation path: String, stale: Record, owner: uid_t,
                                  mine: Record, output: URL) throws {
        for _ in 0..<2 {
            let descriptor = open(RawFilePath.system(guardPath), O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o644)
            if descriptor >= 0 {
                try write(mine, to: descriptor, path: guardPath, output: output)
                return
            }
            let error = errno
            guard error == EEXIST else {
                // Nothing can be created beside it (a read-only folder, or another user's sticky one).
                throw HolosError.unavailable("A reading for \(output.path) that is no longer running (process \(stale.pid) of \(userName(stale.uid))) left its reservation \(path), and it cannot be replaced here: \(String(cString: strerror(error))). \(userName(owner).capitalizedFirst), who owns it, or an administrator can delete it.")
            }
            switch holder(at: guardPath) {
            case .gone:
                continue
            case .running(let record):
                throw HolosError.unavailable("Another reading is already being made for \(output.path): process \(record.pid) of \(userName(record.uid)) is taking over its reservation \(path) (with \(guardPath)).")
            case .otherHost(let record):
                throw HolosError.unavailable("Another reading is already being made for \(output.path): process \(record.pid) of user ID \(record.uid) on \(computer(record)) is taking over its reservation \(path) (with \(guardPath)), which cannot be checked from here. If no reading of that file is running there, delete \(guardPath).")
            case .unreadable(let reason):
                throw HolosError.unavailable("Another reading may be taking over the reservation \(path) of \(output.path): its takeover file \(guardPath) \(reason). If no reading of that file is running, delete \(guardPath).")
            case .ended(let record, let guardOwner, _):
                throw HolosError.unavailable("A reading of \(output.path) (process \(record.pid) of \(userName(record.uid))) stopped while taking over its reservation \(path) and left the takeover file \(guardPath). If no reading of that file is running, delete \(guardPath) (\(userName(guardOwner)) owns it).")
            }
        }
        throw HolosError.unavailable("Another reading is already being made for \(output.path): its reservation \(path) is being taken over (with \(guardPath)).")
    }

    /// Writes `record` into the reservation (or guard) just created, readable by every user
    /// whatever the umask. One that cannot be written is removed.
    private static func write(_ record: Record, to descriptor: Int32, path: String, output: URL) throws {
        defer { close(descriptor) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Strings and numbers only: this cannot fail.
        guard let data = try? encoder.encode(record) else { preconditionFailure("Reservation did not encode.") }
        var failure: Int32 = fchmod(descriptor, 0o644) == 0 ? 0 : errno
        if failure == 0 {
            failure = data.withUnsafeBytes { bytes -> Int32 in
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(descriptor, bytes.baseAddress! + offset, bytes.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return errno
                    }
                    offset += written
                }
                return 0
            }
        }
        guard failure == 0 else {
            _ = unlink(RawFilePath.system(path))
            throw HolosError.io("Could not reserve \(output.path) with \(path): \(String(cString: strerror(failure)))")
        }
    }

    enum Holder {
        /// Removed since it was found.
        case gone
        /// Why it cannot be trusted, as "cannot be read (reason)".
        case unreadable(String)
        /// Its process runs on this Mac.
        case running(Record)
        /// Made on another Mac (or its Mac cannot be told).
        case otherHost(Record)
        /// Made on this Mac by a process that has ended; `owner` is the file's owner, `file` which
        /// file was read.
        case ended(Record, owner: uid_t, file: (device: dev_t, inode: ino_t))
    }

    /// Who holds the reservation at `path`.
    static func holder(at path: String) -> Holder {
        let descriptor = open(RawFilePath.system(path), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            let error = errno
            return error == ENOENT ? .gone : .unreadable("cannot be read (\(String(cString: strerror(error))))")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return .unreadable("is not a regular file")
        }
        guard let data = readAll(descriptor), let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return .unreadable("does not say which process holds it")
        }
        // Only a record from this Mac (by hardware UUID; host names can repeat) can be checked here.
        guard !record.machine.isEmpty, record.machine == machineID else { return .otherHost(record) }
        if let start = processStart(record.pid), start == record.start { return .running(record) }
        return .ended(record, owner: metadata.st_uid, file: (metadata.st_dev, metadata.st_ino))
    }

    private static func readAll(_ descriptor: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: maximumBytes + 1)
        while data.count <= maximumBytes {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[0..<count])
        }
        return nil
    }

    /// When process `pid` started, in microseconds since 1970; nil when no such process runs (a
    /// zombie, which has ended, included).
    static func processStart(_ pid: Int32) -> Int64? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid, Int32(info.kp_proc.p_stat) != SZOMB else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }

    /// This Mac's hardware UUID (`gethostuuid`), the same for every process and user on it and
    /// different on every other Mac, whatever their host names; empty when it cannot be read.
    static let machineID: String = {
        var bytes = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 1, tv_nsec: 0)
        guard gethostuuid(&bytes, &wait) == 0 else { return "" }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }()

    /// The computer a record from another Mac names, for messages.
    private static func computer(_ record: Record) -> String {
        guard !record.host.isEmpty else { return "another computer" }
        return record.host == hostName() ? "another computer also named \(record.host)" : record.host
    }

    static func hostName() -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    private static func userName(_ uid: uid_t) -> String {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return "user ID \(uid)" }
        return "user \(String(cString: name))"
    }

    private static func date(_ seconds: Double) -> String {
        ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
    }

    /// Removes the file at `path` (a reservation or its guard) when it still holds `record`: one
    /// removed by hand and made again by another run is that run's.
    private static func removeIfHolding(_ path: String, _ record: Record) {
        let descriptor = open(RawFilePath.system(path), O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return }
        let data = readAll(descriptor)
        close(descriptor)
        guard let data, (try? JSONDecoder().decode(Record.self, from: data)) == record else { return }
        _ = unlink(RawFilePath.system(path))
    }

    /// Whether `release` ran.
    private let released = NSLock()
    private var isReleased = false

    /// Removes the reservation now (see `removeIfHolding`), where the caller runs (a render does it off the main
    /// actor: the output folder may be on a slow share); once.
    func release() {
        released.lock()
        defer { released.unlock() }
        guard !isReleased else { return }
        isReleased = true
        Self.removeIfHolding(path, record)
    }

    deinit { release() }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// One string for every spelling of one filesystem location, so the locks and cache keys that
/// name a file follow the filesystem's own rules rather than the path's spelling:
/// - the parent folder is its real path (`realpath(3)`: links resolved, "..", and on macOS each
///   component's on-disk case);
/// - the last component (which may not exist yet) is put in Unicode canonical composition and
///   case-folded as `Rule` and the volume's `NameRules` say.
enum ReadingPathIdentity {
    /// How a name's case and Unicode normalization count.
    enum Rule {
        /// For locks: case is folded unless the volume is known to tell names apart by case, and
        /// NFC and NFD spellings are always one, so every spelling that may name one file shares
        /// the lock. On a volume whose rules cannot be told, "Book.m4a" and "book.m4a" (or one
        /// name in NFC and NFD) share a lock, which only serializes them.
        case lock
        /// For render caches and `--resume`: case is folded only when the volume is known to
        /// ignore it, and a name is composed only when the volume is known to treat NFC and NFD
        /// spellings as one (APFS, HFS+), so two spellings share a cache only when they name
        /// one file.
        case exact
    }

    /// How the volume holding a folder compares names; nil where that cannot be told.
    struct NameRules: Equatable {
        /// Whether "Book" and "book" are two names.
        var caseSensitive: Bool?
        /// Whether a name's NFC and NFD spellings name one file.
        var equatesNormalization: Bool?
    }

    typealias VolumeQuery = (String) -> NameRules

    /// The identity of the file `url` names, its path spelled as the URL holds it: as typed for
    /// a `RawFilePath` URL (what `ReadingOutput` gives), decomposed for one Foundation made from a
    /// path string (see `RawFilePath`).
    static func key(_ url: URL, _ rule: Rule = .lock, volume: VolumeQuery = volumeRules) -> String {
        key(path: RawFilePath.standardized(url.path), rule, volume: volume)
    }

    /// The identity of `path`, spelled as given.
    static func key(path: String, _ rule: Rule = .lock, volume: VolumeQuery = volumeRules) -> String {
        // An existing path resolves whole, so a link in the last component is followed too.
        let resolved = realPath(path) ?? path
        let name = (resolved as NSString).lastPathComponent
        let parentPath = (resolved as NSString).deletingLastPathComponent
        let parent = realPath(parentPath)
            ?? URL(fileURLWithPath: parentPath).standardizedFileURL.resolvingSymlinksInPath().path
        let rules = volume(parent)
        let (keepsCase, composes) = switch rule {
        case .lock: (rules.caseSensitive == true, true)
        case .exact: (rules.caseSensitive != false, rules.equatesNormalization == true)
        }
        let folded = normalizedName(name, caseSensitive: keepsCase, composed: composes)
        return parent == "/" ? "/" + folded : parent + "/" + folded
    }

    /// `name` as the volume compares names: composed when `composed`, and case-folded unless
    /// `caseSensitive`. A name not composed keeps its spelling as given.
    static func normalizedName(_ name: String, caseSensitive: Bool, composed: Bool = true) -> String {
        let spelled = composed ? name.precomposedStringWithCanonicalMapping : name
        guard !caseSensitive else { return spelled }
        let folded = spelled.folding(options: [.caseInsensitive], locale: nil)
        return composed ? folded.precomposedStringWithCanonicalMapping : folded
    }

    /// Whether the volume holding `folder` tells names apart by case; false when unknown.
    static func caseSensitive(_ folder: String) -> Bool {
        volumeCaseSensitivity(folder) ?? false
    }

    /// How the volume holding `folder` compares names, as far as it can be told.
    static func volumeRules(_ folder: String) -> NameRules {
        NameRules(caseSensitive: volumeCaseSensitivity(folder),
                  equatesNormalization: volumeEquatesNormalization(folder))
    }

    /// Whether the volume holding `folder` tells names apart by case, as the volume reports it;
    /// nil when that cannot be told.
    static func volumeCaseSensitivity(_ folder: String) -> Bool? {
        let values = try? URL(fileURLWithPath: folder, isDirectory: true)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames
    }

    /// Whether the volume holding `folder` treats a name's NFC and NFD spellings as one file:
    /// true for APFS and HFS+ (by their format, `statfs`'s `f_fstypename`); nil for any other
    /// or when it cannot be told (a network share may keep the bytes as given).
    static func volumeEquatesNormalization(_ folder: String) -> Bool? {
        guard let type = fileSystemType(folder) else { return nil }
        return normalizationInsensitiveTypes.contains(type) ? true : nil
    }

    static let normalizationInsensitiveTypes: Set<String> = ["apfs", "hfs"]

    /// The format name of the volume holding `path` ("apfs", "hfs", "smbfs", "exfat"), or nil.
    static func fileSystemType(_ path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }.lowercased()
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Which file a path named at one moment (see `ExclusivePublisher.FileIdentity`).
public typealias ReadingFileIdentity = ExclusivePublisher.FileIdentity

/// The names of the temporary files a reading creates, and the removal of ones an interrupted run
/// left behind. Each name carries a marker only this reading's runs use, so a sweep never touches
/// another reading's (or anyone else's) files:
/// - beside the output: `.holos-join-<reading key>-<run UUID>.m4a`, the joined file before it is
///   published, and `.holos-join-<reading key>-<run UUID>-<UUID>.m4a`, the temporary
///   `AudioBookWriter` encodes it into. The key is a hash of the cache directory, whose lock
///   serializes runs, so one with another run's UUID is left over from an earlier run;
/// - in the cache: `.holos-manifest-<UUID>.tmp`, a manifest being saved;
/// - in the cache's `parts`: `.holos-<UUID>.<ext>` from the speech renderer and
///   `.invalid-<UUID>-<part>`, a part that failed its checksum.
enum ReadingTemporaries {
    static let joinPrefix = ".holos-join-"
    static let manifestPrefix = ".holos-manifest-"
    static let manifestSuffix = ".tmp"
    static let rendererPrefix = ".holos-"
    static let invalidPrefix = ".invalid-"

    static func key(for directory: URL) -> String { String(ReadingDirectoryLock.key(for: directory).prefix(16)) }

    /// The private folder beside the output that the reading's partly written file is moved into to be removed
    /// (see `ExclusivePublisher.removeVerified`), when a publication fails or a resume removes a copy a crash cut off:
    /// `.holos-delete-<reading key>.publish`. Derived from the cache, so a removal a crash cut off after the move is
    /// found there by the next resume or Delete (see `recoverPublicationAside`).
    static func publicationToken(key: String) -> String { ExclusivePublisher.removalPrefix + key + ".publish" }

    /// Where `publicationToken`'s folder keeps the partly written file of `output`.
    static func publicationAside(output: URL, key: String) -> URL {
        RawFilePath.appending(output.lastPathComponent, to: RawFilePath.appending(
            publicationToken(key: key), to: output.deletingLastPathComponent()))
    }

    /// Finishes a removal of the reading's partly written file that a crash cut off after it was moved aside: the
    /// file in `publicationAside` goes when it is that file (`identity`, the manifest's `publishing`), then the
    /// folder. Anything else there (another file, or one that cannot be checked) is an error and is left: the place
    /// is only the reading's, so a later removal must not find it taken.
    static func recoverPublicationAside(output: URL, key: String, evidence: ReadingLibrary.Evidence) throws {
        let file = publicationAside(output: output, key: key)
        let folder = file.deletingLastPathComponent()
        guard try ReadingOutput.exists(folder) else { return }
        if try ReadingOutput.exists(file) {
            guard try evidence.isPartial(file) else {
                throw HolosError.io("\(file.path) was left by an earlier try to save this reading, and it is not the "
                    + "reading's partly written file. Move it away or remove it in Finder, then try again.")
            }
            try ExclusivePublisher.removeFile(file)
        }
        guard rmdir(RawFilePath.system(folder)) == 0 || errno == ENOENT else {
            throw HolosError.io("\(folder.path), left by an earlier try to save this reading, could not be removed: "
                + String(cString: strerror(errno)) + ". Remove it in Finder, then try again.")
        }
    }

    static func joinName(key: String, run: UUID) -> String {
        "\(joinPrefix)\(key)-\(run.uuidString).\(ReadingAudioFormat.fileExtension)"
    }

    /// The join file of run `run` beside `output`, in its folder as spelled (see `RawFilePath`).
    static func joinURL(beside output: URL, key: String, run: UUID) -> URL {
        RawFilePath.appending(joinName(key: key, run: run), to: output.deletingLastPathComponent())
    }

    static func manifestName() -> String { "\(manifestPrefix)\(UUID().uuidString)\(manifestSuffix)" }

    /// Removes this reading's temporaries from earlier runs: regular files owned by this user whose
    /// names match exactly, except the current run's.
    static func sweep(workDirectory: URL, outputFolder: URL, key: String, currentRun: UUID) {
        _ = sweepJoins(outputFolder: outputFolder, key: key, currentRun: currentRun)
        remove(in: workDirectory) { name in
            uuid(between: manifestPrefix, and: manifestSuffix, in: name) != nil
        }
        remove(in: workDirectory.appendingPathComponent("parts")) { name in
            if name.hasPrefix(invalidPrefix) {
                let rest = name.dropFirst(invalidPrefix.count)
                guard rest.count > 37, UUID(uuidString: String(rest.prefix(36))) != nil else { return false }
                return rest.dropFirst(36).first == "-"
            }
            guard name.hasPrefix(rendererPrefix), let dot = name.lastIndex(of: ".") else { return false }
            let stem = name[name.index(name.startIndex, offsetBy: rendererPrefix.count)..<dot]
            let ext = name[name.index(after: dot)...]
            return UUID(uuidString: String(stem)) != nil && !ext.isEmpty
                && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    /// The run in a join file's name (`<start><run UUID><end>`), or in the name of the temporary
    /// `AudioBookWriter` encodes it into (`<start><run UUID>-<UUID><end>`); nil for any other name.
    static func joinRun(_ name: String, start: String, end: String) -> UUID? {
        if let run = uuid(between: start, and: end, in: name) { return run }
        guard name.hasPrefix(start), name.hasSuffix(end) else { return nil }
        let middle = name.dropFirst(start.count).dropLast(end.count)
        guard middle.count == 36 + 1 + 36, middle.dropFirst(36).first == "-",
              UUID(uuidString: String(middle.suffix(36))) != nil else { return nil }
        return UUID(uuidString: String(middle.prefix(36)))
    }

    static func uuid(between prefix: String, and suffix: String, in name: String) -> UUID? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix), name.count > prefix.count + suffix.count else { return nil }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count)))
    }

    /// Removes this reading's joined files from runs other than `currentRun` beside the output (see `sweep`), and
    /// the places aside a copy of one was being removed through when a crash came (`.holos-delete-<join name>`, see
    /// `AudioBookWriter.cleanupToken`). Returns what could not be looked at or removed (nil when all is gone), for a
    /// Delete, which keeps the reading until it is.
    static func sweepJoins(outputFolder: URL, key: String, currentRun: UUID) -> String? {
        let start = "\(joinPrefix)\(key)-"
        let end = "." + ReadingAudioFormat.fileExtension
        func isStale(_ name: String) -> Bool { joinRun(name, start: start, end: end).map { $0 != currentRun } ?? false }
        guard let names = RawFilePath.names(in: outputFolder) else {
            let error = errno
            return error == ENOENT ? nil
                : "\(outputFolder.path) could not be looked into: \(String(cString: strerror(error)))."
        }
        var problems: [String] = []
        func unlinkOwn(_ url: URL) {
            let path = RawFilePath.system(url)
            var metadata = stat()
            guard lstat(path, &metadata) == 0 else {
                // Only "not there" is gone: a file that cannot be looked up may still be there.
                if errno != ENOENT {
                    problems.append("\(url.path) could not be checked: \(String(cString: strerror(errno))).")
                }
                return
            }
            guard (metadata.st_mode & S_IFMT) == S_IFREG, metadata.st_uid == getuid() else { return }
            if unlink(path) != 0, errno != ENOENT {
                problems.append("\(url.path) could not be removed: \(String(cString: strerror(errno))).")
            }
        }
        for name in names {
            if isStale(name) {
                unlinkOwn(RawFilePath.appending(name, to: outputFolder))
            } else if name.hasPrefix(ExclusivePublisher.removalPrefix),
                      case let joined = String(name.dropFirst(ExclusivePublisher.removalPrefix.count)), isStale(joined) {
                let folder = RawFilePath.appending(name, to: outputFolder)
                unlinkOwn(RawFilePath.appending(joined, to: folder))
                if rmdir(RawFilePath.system(folder)) != 0, errno != ENOENT {
                    problems.append("\(folder.path) could not be removed: \(String(cString: strerror(errno))).")
                }
            }
        }
        return problems.isEmpty ? nil : problems.joined(separator: " ")
    }

    /// Listed and removed with `folder` spelled as given (see `RawFilePath`).
    private static func remove(in folder: URL, where matches: (String) -> Bool) {
        guard let names = RawFilePath.names(in: folder) else { return }
        for name in names where matches(name) {
            let path = RawFilePath.system(RawFilePath.appending(name, to: folder))
            var metadata = stat()
            guard lstat(path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG,
                  metadata.st_uid == getuid() else { continue }
            _ = unlink(path)
        }
    }
}

/// Creating a new reading's cache as one step: it is made under a temporary name beside its
/// place (`.holos-init-<lock key>-<UUID>`), filled (`parts`, `source.txt`, the first manifest), and
/// only then renamed into place. A cache is therefore never at its place without a manifest, and
/// a failure removes everything the run created, so the reading can simply be started again.
enum ReadingCache {
    /// The steps of `create`, after each of which a test may fail it.
    enum Step: CaseIterable { case directory, parts, source, manifest }

    static let stagingPrefix = ".holos-init-"

    /// `.holos-init-<lock key>-<UUID>`, a new cache's name while it is made.
    static func stagingName(key: String) -> String { "\(stagingPrefix)\(key)-\(UUID().uuidString)" }

    /// `directory`'s contents, made beside it and renamed into place. Fails, leaving nothing,
    /// when anything is in the way.
    static func create(_ directory: URL, source: Data, manifest: ReadingManifest,
                       fault: (Step) throws -> Void = { _ in }) throws {
        let folder = ReadingDirectoryLock.folder(beside: directory)
        let staging = folder.appendingPathComponent(
            stagingName(key: ReadingDirectoryLock.key(for: directory)), isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try fault(.directory)
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("parts"),
                                                    withIntermediateDirectories: false)
            try fault(.parts)
            try source.write(to: staging.appendingPathComponent("source.txt"), options: [.withoutOverwriting])
            try fault(.source)
            try save(manifest, to: staging.appendingPathComponent(ReadingManifest.fileName))
            try fault(.manifest)
            try commit(staging, to: folder.appendingPathComponent(directory.lastPathComponent))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Renames the filled cache into place, never over anything there: exclusively where the
    /// volume can, else with rename(2), which replaces only an empty folder.
    private static func commit(_ staging: URL, to directory: URL) throws {
        if ReadingPublisher.systemExclusiveRename(staging.path, directory.path) == 0 { return }
        var error = errno
        if error == ENOTSUP || error == EINVAL || error == ENOSYS {
            if rename(staging.path, directory.path) == 0 { return }
            error = errno
        }
        if error == EEXIST || error == ENOTEMPTY || error == ENOTDIR || error == EISDIR {
            throw HolosError.invalidInput("A reading already exists at \(directory.path). Use --resume to continue it.")
        }
        throw HolosError.io("Could not create the reading cache \(directory.path): \(String(cString: strerror(error)))")
    }

    /// Removes the caches that runs killed in the middle of `create` left beside `directory`:
    /// this reading's (whose lock the caller holds), and any other reading's whose lock no run
    /// holds. Only folders owned by this user and named as `create` names them are touched.
    static func sweep(beside directory: URL) {
        let folder = ReadingDirectoryLock.folder(beside: directory)
        let own = ReadingDirectoryLock.key(for: directory)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names {
            guard let key = stagingKey(name) else { continue }
            let staging = folder.appendingPathComponent(name, isDirectory: true)
            var metadata = stat()
            guard lstat(staging.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
                  metadata.st_uid == getuid() else { continue }
            if key == own {
                try? FileManager.default.removeItem(at: staging)
            } else if let lock = ReadingDirectoryLock.acquireIfIdle(key: key, in: folder) {
                withExtendedLifetime(lock) { try? FileManager.default.removeItem(at: staging) }
            }
        }
    }

    /// The lock key in a name `create` gives, or nil for any other name.
    static func stagingKey(_ name: String) -> String? {
        guard name.hasPrefix(stagingPrefix) else { return nil }
        let rest = name.dropFirst(stagingPrefix.count)
        guard rest.count == 64 + 1 + 36 else { return nil }
        let key = rest.prefix(64)
        guard key.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }), rest.dropFirst(64).first == "-",
              UUID(uuidString: String(rest.suffix(36))) != nil else { return nil }
        return String(key)
    }

    /// Removes a cache that an earlier version (which created it in place) left half made: a
    /// folder owned by this user, named as caches are (`Output-<16 hex digits>` or a UUID), with
    /// no manifest and nothing in it but what that creation writes (an empty `parts`,
    /// `source.txt`, a manifest being saved). Returns whether it was removed; anything else is kept.
    static func removeAbandoned(_ directory: URL) -> Bool {
        guard isCacheName(directory.lastPathComponent) else { return false }
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == getuid(),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        var files: [String] = []
        var parts: String?
        for name in names {
            let path = directory.appendingPathComponent(name).path
            var entry = stat()
            guard lstat(path, &entry) == 0, entry.st_uid == getuid() else { return false }
            let type = entry.st_mode & S_IFMT
            if name == "parts", type == S_IFDIR,
               (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true {
                parts = path
            } else if type == S_IFREG, name == "source.txt"
                        || ReadingTemporaries.uuid(between: ReadingTemporaries.manifestPrefix,
                                                   and: ReadingTemporaries.manifestSuffix, in: name) != nil {
                files.append(path)
            } else {
                return false
            }
        }
        for path in files { _ = unlink(path) }
        if let parts { _ = rmdir(parts) }
        return rmdir(directory.path) == 0
    }

    /// `Output-<16 lowercase hex digits>` (a reading with `--output`) or a UUID (one without).
    static func isCacheName(_ name: String) -> Bool {
        if UUID(uuidString: name) != nil { return true }
        let prefix = "Output-"
        guard name.hasPrefix(prefix) else { return false }
        let digest = name.dropFirst(prefix.count)
        return digest.count == 16 && digest.allSatisfy { $0.isASCII && $0.isHexDigit && !$0.isUppercase }
    }
}

func sha256(_ data: Data) -> String {
    hex(SHA256.hash(data: data))
}

private func hex(_ digest: SHA256.Digest) -> String {
    digest.map { String(format: "%02x", $0) }.joined()
}

/// SHA-256 of a file read in 1 MiB chunks, so a book-length file never sits in memory at once.
/// `url` opened for reading with its path as spelled (`FileHandle(forReadingFrom:)` would
/// decompose it; see `RawFilePath`): the output, its join file, and a manifest found through
/// `--output` are in the folder the user typed.
private func rawHandle(_ url: URL) throws -> FileHandle {
    try openRegularFile(url)
}

/// A reading's file could not be opened: why, and the `errno` (`EFTYPE` for one that is not a regular file).
public struct ReadingFileError: LocalizedError, Sendable {
    public let message: String
    public let code: Int32

    public var errorDescription: String? { message }
}

/// `url` opened for reading, its path as spelled (see `RawFilePath`), only when it is a regular file: opened without
/// waiting (`O_NONBLOCK`), so a FIFO or a device put at the path is refused at once instead of blocking the open until
/// a writer comes, and checked on the open descriptor. Every file of a reading that is read (a checksum, a manifest,
/// the index, a saved text, a finished file played) is opened here.
func openRegularFile(_ url: URL, followLinks: Bool = true) throws -> FileHandle {
    let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | (followLinks ? 0 : O_NOFOLLOW)
    let descriptor = open(RawFilePath.system(url), flags)
    guard descriptor >= 0 else {
        let error = errno
        throw ReadingFileError(message: "Could not read \(url.path): \(String(cString: strerror(error)))", code: error)
    }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
        close(descriptor)
        throw ReadingFileError(message: "Could not read \(url.path): it is not a regular file.", code: EFTYPE)
    }
    // Reads of a regular file never wait anyway; blocking reads again, as the callers expect.
    _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) & ~O_NONBLOCK)
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

/// The file's SHA-256. `isCancelled` is asked between chunks (default: the current task's cancellation), so a Stop
/// ends a long checksum on a slow drive with `CancellationError` instead of reading the whole file.
func fileSHA256(_ url: URL, isCancelled: () -> Bool = { Task.isCancelled }) throws -> String {
    let handle = try rawHandle(url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        if isCancelled() { throw CancellationError() }
        let done = try autoreleasepool { () throws -> Bool in
            guard let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty else { return true }
            hasher.update(data: chunk)
            return false
        }
        if done { break }
    }
    return hex(hasher.finalize())
}

/// `fileSHA256` off the main actor, where `ReadingPipeline` runs: a rendered part or a finished reading is megabytes,
/// and a resume checks every part, which would stall the app's window. The caller's cancellation reaches the checksum
/// (checked between chunks), and a cancelled caller gets `CancellationError` even when the checksum had finished.
func fileSHA256OffMain(_ url: URL) async throws -> String {
    let checksum = try await offMain { try fileSHA256(url) }
    try Task.checkCancellation()
    return checksum
}

/// Runs `work` off the main actor (a detached task), with the caller's cancellation passed on to it and the test
/// stand-ins the reading's file code reads (task-locals, which a detached task does not inherit) carried over.
public func offMain<Result: Sendable>(priority: TaskPriority = .userInitiated,
                                      _ work: @escaping @Sendable () throws -> Result) async throws -> Result {
    let volume = RawFilePath.volume
    let volumes = ReadingOutput.volumesFolder
    let nameLimit = ReadingOutput.volumeNameLimit
    let lockCall = ReadingDirectoryLock.lockCall
    let takeoverStep = ReadingOutputReservation.takeoverStep
    let task = Task.detached(priority: priority) {
        try RawFilePath.$volume.withValue(volume) {
            try ReadingOutput.$volumesFolder.withValue(volumes) {
                try ReadingOutput.$volumeNameLimit.withValue(nameLimit) {
                    try ReadingDirectoryLock.$lockCall.withValue(lockCall) {
                        try ReadingOutputReservation.$takeoverStep.withValue(takeoverStep) { try work() }
                    }
                }
            }
        }
    }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}

/// The contents of a file expected to be small; a larger one is an error, not read whole.
func readSmallFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let handle = try rawHandle(url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else {
        throw HolosError.invalidInput("\(url.path) is larger than \(maximumBytes) bytes.")
    }
    return data
}

private func save(_ manifest: ReadingManifest, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try atomicWrite(encoder.encode(manifest), to: url)
}

private func atomicWrite(_ data: Data, to url: URL) throws {
    let temporary = url.deletingLastPathComponent().appendingPathComponent(ReadingTemporaries.manifestName())
    try data.write(to: temporary, options: [.withoutOverwriting])
    if rename(temporary.path, url.path) != 0 {
        let message = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: temporary)
        throw HolosError.io("Could not save reading metadata: \(message)")
    }
}

public enum SemanticChunker {
    public struct Chunk: Sendable, Equatable {
        public let index: Int
        public let offset: Int
        public let length: Int
        public let text: String
    }

    public static func chunks(_ text: String, maxUTF16Units: Int = 3_000) -> [Chunk] {
        precondition(maxUTF16Units > 0)
        let characters = Array(text)
        var positions = [Int](repeating: 0, count: characters.count + 1)
        for index in characters.indices { positions[index + 1] = positions[index] + characters[index].utf16.count }
        var result: [Chunk] = []
        var start = 0
        while start < characters.count {
            var limit = start + 1
            while limit < characters.count && positions[limit + 1] - positions[start] <= maxUTF16Units {
                limit += 1
            }
            var end = limit
            if end < characters.count {
                let minimum = start + max(1, (end - start) / 3)
                for candidate in stride(from: end, through: minimum, by: -1) {
                    if candidate >= 2 && characters[candidate - 1] == "\n" && characters[candidate - 2] == "\n" {
                        end = candidate; break
                    }
                }
                if end == limit {
                    for candidate in stride(from: end, through: minimum, by: -1) {
                        if candidate > start && ".!?".contains(characters[candidate - 1]) &&
                            (candidate == characters.count || characters[candidate].isWhitespace) {
                            end = candidate; break
                        }
                    }
                }
                if end == limit {
                    for candidate in stride(from: end, through: minimum, by: -1) {
                        if candidate > start && characters[candidate - 1].isWhitespace {
                            end = candidate; break
                        }
                    }
                }
            }
            let chunkText = String(characters[start..<end])
            result.append(Chunk(index: result.count, offset: positions[start],
                                length: positions[end] - positions[start], text: chunkText))
            start = end
        }
        return result
    }
}
