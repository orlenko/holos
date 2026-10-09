import Foundation
import HolosCore
import HolosSynthesis

/// The saved reading `voiceislocal read --resume` continues when no `--voice` is given: the voice it was started with
/// is read from its manifest, never guessed (it may have been any voice, or a default that has changed since).
/// `--output` naming the reading's folder: that folder's manifest. An explicit output, whose cache is keyed by every
/// setting the reading was made with: of the readings in the Readings folder made for that same file from the same
/// text, with the same rate, title, author, and language, the one written to last (its manifest is saved after every
/// part), whatever voice it used. Nil when none is found (the resume then says there is no reading to resume).
public enum ReadingResumeVoice {
    /// The saved reading for `script` read into `output` (see above), found off the main actor (a Readings folder
    /// can hold many readings, on a slow drive); a Stop ends the search. `voice`: only a reading made with it (a
    /// `--voice` given with `--resume`).
    public static func saved(output: String?, name: String, readingsRoot: URL, script: ReadingScript, rate: Float?,
                             metadata: AudioBookMetadata, voice: String? = nil) async throws -> ReadingManifest? {
        let plan = ReadingPipeline.plan(script.parts(maxUTF16Units: ReadingPipeline.defaultMaxPartUTF16Units))
        let source = sha256(Data(script.text.utf8))
        return try await offMain {
            try saved(output: output, name: name, readingsRoot: readingsRoot, sourceSHA256: source, plan: plan,
                      rate: rate, metadata: metadata, voice: voice)
        }
    }

    /// The search itself: each manifest read once; the part plan compared too, since documents with the same text can
    /// be split into other parts and chapters (another reading). Only a manifest of this schema and audio format is a
    /// candidate: another one cannot be resumed here, so it never wins by being newer.
    static func saved(output: String?, name: String, readingsRoot: URL, sourceSHA256: String, plan: [ReadingPart],
                      rate: Float?, metadata: AudioBookMetadata, voice: String? = nil,
                      volume: ReadingPathIdentity.VolumeQuery = ReadingPathIdentity.volumeRules) throws
        -> ReadingManifest? {
        guard let (location, destination) = try? ReadingOutput.resolve(
                  output: output, name: name, identity: "", readingsRoot: readingsRoot) else { return nil }
        if destination == .readingFolder { return manifest(in: location.workDirectory) }
        guard destination == .explicit,
              let names = try? FileManager.default.contentsOfDirectory(atPath: readingsRoot.path) else { return nil }
        let file = ReadingPathIdentity.key(location.output, .exact, volume: volume)
        var latest: (manifest: ReadingManifest, changed: Date)?
        for name in names where name.hasPrefix("Output-") {
            try Task.checkCancellation()
            let folder = readingsRoot.appendingPathComponent(name, isDirectory: true)
            guard let (manifest, changed) = manifestAndDate(in: folder),
                  manifest.schemaVersion == ReadingManifest.currentSchemaVersion, manifest.format == .current,
                  manifest.sourceSHA256 == sourceSHA256,
                  voice.map({ $0 == manifest.voiceIdentifier }) ?? true,
                  manifest.rate == rate, manifest.title == metadata.title, manifest.author == metadata.author,
                  manifest.language == metadata.language, manifest.comment == metadata.comment,
                  ReadingPipeline.samePlan(manifest.parts, plan),
                  manifest.output.utf8.elementsEqual(location.output.path.utf8)
                      || ReadingPathIdentity.key(path: manifest.output, .exact, volume: volume).utf8
                          .elementsEqual(file.utf8) else { continue }
            if latest.map({ changed > $0.changed }) ?? true { latest = (manifest, changed) }
        }
        return latest?.manifest
    }

    /// Refuses a reading made with a natural voice from another commit of the voices: its parts cannot be joined
    /// with the current ones, so it cannot be resumed, whatever voice is asked for now or whether the pack is
    /// installed. Said before anything else (reinstalling a pack would not help).
    /// `again`: what to do instead (the app says it its way).
    public static func checkRevision(_ manifest: ReadingManifest,
                                     again: String = "Make it again without --resume.") throws {
        let id = manifest.voiceIdentifier
        guard NaturalVoiceCatalog.isNatural(id), manifest.modelRevision != ReadingPipeline.modelRevision(for: id)
        else { return }
        let name = NaturalVoiceCatalog.voice(id: id)?.title ?? id
        throw HolosError.invalidInput("This reading was started with \(name) from another version of the natural "
            + "voices (\(manifest.modelRevision ?? "unknown")); its parts cannot be joined with the current ones, so it "
            + "cannot be resumed. \(again)")
    }

    /// The voice of a saved reading, when it can be resumed here. A natural voice made with another commit of the
    /// voices cannot be, installed or not, and that is said first (installing the pack again would not help); one
    /// whose pack is not installed says to install it.
    public static func voice(of manifest: ReadingManifest, installed: Set<NaturalVoicePack>) throws -> String {
        try checkRevision(manifest)
        let id = manifest.voiceIdentifier
        guard NaturalVoiceCatalog.isNatural(id) else { return id }
        guard let voice = NaturalVoiceCatalog.voice(id: id) else {
            throw HolosError.unavailable("The voice this reading was started with is not available: \(id)")
        }
        guard installed.contains(voice.pack) else {
            throw HolosError.unavailable("This reading was started with \(voice.title), and the "
                + "\(voice.pack.languageName) natural voices are no longer installed. Run voiceislocal setup "
                + "--natural-voices" + (voice.pack == .english ? "" : " --language \(voice.pack.languageCode)")
                + ", then resume.")
        }
        return id
    }

    /// The manifest of the reading whose cache is `directory` (this app's kind only); nil when there is none.
    public static func manifest(in directory: URL) -> ReadingManifest? {
        manifestAndDate(in: directory)?.manifest
    }

    /// A reading's manifest, read once (this app's kind only), and when it was last written.
    static func manifestAndDate(in directory: URL) -> (manifest: ReadingManifest, changed: Date)? {
        let url = directory.appendingPathComponent(ReadingManifest.fileName)
        guard let data = try? readSmallFile(url, maximumBytes: ReadingManifest.maximumBytes),
              let manifest = try? JSONDecoder().decode(ReadingManifest.self, from: data),
              manifest.kind == ReadingManifest.readingKind else { return nil }
        let changed = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date)
            ?? .distantPast
        return (manifest, changed)
    }
}
