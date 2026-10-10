import Darwin
import Foundation
import HolosCore
import HolosSynthesis

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
        // a bad one never leaves a cache behind that cannot be resumed. A resume of a reading from another commit of
        // the natural voices is refused before that: checking its voice would ask for a pack that cannot help.
        if resume { try await Self.refuseAnotherCommit(in: directory) }
        try validateSettings(script: script, voiceIdentifier: voiceIdentifier, rate: rate, metadata: metadata,
                             location: location)
        // Planned off the main actor: a book is split into hundreds of parts, each hashed.
        let (planned, expected) = try await offMain { () -> ([ReadingScript.Part], [ReadingPart]) in
            let planned = script.parts(maxUTF16Units: maxPartUTF16Units)
            return (planned, Self.plan(planned))
        }
        try Task.checkCancellation()
        let manifestURL = directory.appendingPathComponent(ReadingManifest.fileName)
        // This run's name for the joined file.
        let run = UUID()
        // The locations are checked, the lock and the reservation taken, and the cache made or its manifest read,
        // off the main actor: the output folder may be on a slow share. The lock and the reservation are held until
        // this render returns.
        let (text, fault) = (script.text, initializationFault)
        // Saved with a new reading (a resume keeps those it saved).
        let settings = renderer.renderSettings(for: voiceIdentifier)
        let prepared = try await offMain {
            try Self.prepare(directory: directory, output: output, resume: resume, text: text, expected: expected,
                             voiceIdentifier: voiceIdentifier, rate: rate, metadata: metadata, settings: settings,
                             run: run, fault: fault)
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
                                                       rate: rate, savedSettings: manifest.rendererSettings,
                                                       to: audio)
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
                                    voiceIdentifier: String, rate: Float?, metadata: AudioBookMetadata,
                                    settings: [String: String]? = nil, run: UUID,
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
            try ReadingResumeVoice.checkRevision(manifest, again: "Delete it and make it again.")
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
                                       modelRevision: modelRevision(for: voiceIdentifier),
                                       rendererSettings: settings)
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

    /// Whether a saved part plan is the one `planned` gives (its parts' places, texts, chapters, and sections).
    nonisolated static func samePlan(_ saved: [ReadingPart], _ planned: [ReadingPart]) -> Bool {
        saved.count == planned.count && zip(saved, planned).allSatisfy { samePlan($0, $1) }
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
