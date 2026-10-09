import Foundation
import HolosCore
import HolosSynthesis
import Testing
@testable import HolosContent

/// `voiceislocal read --resume` without `--voice` finds the reading it continues, and its voice, from the saved
/// manifests (`ReadingResumeVoice`), and `--print-text` names the file it would write (`ReadingPreview.printed`).
@Suite struct ReadingResumeVoiceTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-resume-\(UUID().uuidString)")
    private let apple = "com.apple.voice.premium.en-US.Ava"
    private let natural = "pocket:en:alba"
    private let metadata = AudioBookMetadata(title: "Garden", author: nil, language: "en", comment: "c")
    private var readings: URL { root.appendingPathComponent("Readings", isDirectory: true) }
    private var output: URL { root.appendingPathComponent("Garden.m4a") }

    private func manifest(voice: String, output: URL, source: String = "s", rate: Float? = nil,
                          modelRevision: String? = nil) -> ReadingManifest {
        ReadingManifest(kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
                        sourceSHA256: source, voiceIdentifier: voice, rate: rate, title: "Garden", author: nil,
                        language: "en", comment: "c", format: .current, output: output.path, outputSHA256: nil,
                        duration: nil, chapters: [], status: "incomplete", parts: [], modelRevision: modelRevision)
    }

    /// Saves a reading's manifest where its cache would be for `output` (the folder name is the cache's, keyed by the
    /// output and the reading's settings), changed at `changed`.
    private func start(_ manifest: ReadingManifest, changed: Date = Date()) throws {
        let (location, _) = try ReadingOutput.resolve(output: manifest.output, name: "Garden.m4a",
                                                      identity: "\(manifest.voiceIdentifier)-\(manifest.sourceSHA256)"
                                                          + "-\(String(describing: manifest.rate))",
                                                      readingsRoot: readings)
        try FileManager.default.createDirectory(at: location.workDirectory, withIntermediateDirectories: true)
        let url = location.workDirectory.appendingPathComponent(ReadingManifest.fileName)
        try JSONEncoder().encode(manifest).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: changed], ofItemAtPath: url.path)
    }

    private func saved(rate: Float? = nil) -> ReadingManifest? {
        ReadingResumeVoice.saved(output: output.path, name: "Garden.m4a", readingsRoot: readings, sourceSHA256: "s",
                                 rate: rate, metadata: metadata)
    }

    @Test func aReadingStartedWithAnyVoiceIsFound() throws {
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: true)
        #expect(saved() == nil)
        // Started with a voice given by --voice, none of today's defaults.
        let fred = "com.apple.speech.synthesis.voice.Fred"
        try start(manifest(voice: fred, output: output))
        #expect(saved()?.voiceIdentifier == fred)
        // Readings of another file, of other text, or at another rate are not this one.
        try start(manifest(voice: apple, output: root.appendingPathComponent("Other.m4a")),
                  changed: Date(timeIntervalSinceNow: 60))
        try start(manifest(voice: apple, output: output, source: "other text"), changed: Date(timeIntervalSinceNow: 60))
        try start(manifest(voice: apple, output: output, rate: 0.6), changed: Date(timeIntervalSinceNow: 60))
        #expect(saved()?.voiceIdentifier == fred)
        #expect(saved(rate: 0.6)?.voiceIdentifier == apple)
    }

    @Test func theLatestOfSeveralReadingsOfTheSameOutputResumes() throws {
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: true)
        // Started with Alba, stopped; Alba's pack removed; the same text started again with the Apple voice.
        try start(manifest(voice: natural, output: output, modelRevision: NaturalVoiceModels.revision),
                  changed: Date(timeIntervalSinceNow: -3_600))
        try start(manifest(voice: apple, output: output))
        #expect(saved()?.voiceIdentifier == apple)
        // Had the natural reading been the later one, it would resume (and ask for its pack).
        try start(manifest(voice: natural, output: output, modelRevision: NaturalVoiceModels.revision),
                  changed: Date(timeIntervalSinceNow: 60))
        #expect(saved()?.voiceIdentifier == natural)
    }

    @Test func aReadingsFolderResumesWithTheVoiceItsManifestSaved() throws {
        let folder = readings.appendingPathComponent("1234", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest(voice: apple, output: folder.appendingPathComponent("Garden.m4a")))
            .write(to: folder.appendingPathComponent(ReadingManifest.fileName))
        #expect(ReadingResumeVoice.saved(output: folder.path, name: "Garden.m4a", readingsRoot: readings,
                                         sourceSHA256: "s", rate: nil, metadata: metadata)?.voiceIdentifier == apple)
    }

    @Test func aNaturalReadingFromAnotherCommitIsRefusedBeforeAskingForItsPack() throws {
        let old = manifest(voice: natural, output: output, modelRevision: "0000000000000000000000000000000000000000")
        // Pack removed and the voices updated since: no use reinstalling (a 530 MB download) to be refused then.
        let error = #expect(throws: HolosError.self) { try ReadingResumeVoice.voice(of: old, installed: []) }
        #expect(error?.localizedDescription.contains("another version of the natural voices") == true)
        #expect(error?.localizedDescription.contains("setup --natural-voices") == false)
        #expect(throws: HolosError.self) { try ReadingResumeVoice.voice(of: old, installed: [.english]) }
        // The same commit, pack removed: install it again.
        let current = manifest(voice: natural, output: output, modelRevision: NaturalVoiceModels.revision)
        let missing = #expect(throws: HolosError.self) { try ReadingResumeVoice.voice(of: current, installed: []) }
        #expect(missing?.localizedDescription.contains("setup --natural-voices") == true)
        #expect(try ReadingResumeVoice.voice(of: current, installed: [.english]) == natural)
        #expect(try ReadingResumeVoice.voice(of: manifest(voice: apple, output: output), installed: []) == apple)
    }

    @Test func printTextNamesTheFileNotTheVoice() throws {
        let folder = root.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = ReadableDocument(title: "Garden", sections: [.init(paragraphs: ["Hello there."])])
        let script = ReadingScript(document: document)
        let text = try ReadingPreview.printed(
            script: script, metadata: AudioBookMetadata(title: "Garden", author: nil, language: "en"),
            voiceName: "Natural — Alba (English)", voiceID: natural, output: folder.path, fileName: "Garden.m4a",
            identity: "identity", readingsRoot: readings)
        let lines = text.components(separatedBy: "\n")
        #expect(lines.contains("Voice: Natural — Alba (English) (pocket:en:alba)"))
        #expect(lines.contains { $0.hasPrefix("File: ") && $0.hasSuffix("/Out/Garden.m4a") })
    }
}
