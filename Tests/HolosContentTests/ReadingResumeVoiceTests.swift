import Foundation
import HolosCore
import HolosSynthesis
import Testing
@testable import HolosContent

/// `voiceislocal read --resume` without `--voice` finds the voice the reading was started with (`ReadingResumeVoice`),
/// and `--print-text` names the file it would write (`ReadingPreview.printed`).
@Suite struct ReadingResumeVoiceTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-resume-\(UUID().uuidString)")
    private let apple = "com.apple.voice.premium.en-US.Ava"
    private let natural = "pocket:en:alba"

    private func manifest(voice: String, output: URL) -> ReadingManifest {
        ReadingManifest(kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
                        sourceSHA256: "s", voiceIdentifier: voice, rate: nil, title: "Garden", author: nil,
                        language: "en", comment: "c", format: .current, output: output.path, outputSHA256: nil,
                        duration: nil, chapters: [], status: "incomplete", parts: [])
    }

    private func save(_ manifest: ReadingManifest, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent(ReadingManifest.fileName))
    }

    private func identity(_ voice: String) -> String { "identity-of-\(voice)" }

    @Test func anExplicitOutputResumesWithTheVoiceItsCacheWasMadeWith() throws {
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        let output = root.appendingPathComponent("Garden.m4a")
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: true)
        // Started with the Apple voice, before natural voices were installed.
        let (location, _) = try ReadingOutput.resolve(output: output.path, name: "Garden.m4a",
                                                      identity: identity(apple), readingsRoot: readings)
        try save(manifest(voice: apple, output: output), in: location.workDirectory)
        // Now the natural voice would be the default: it comes first, and has no reading.
        #expect(ReadingResumeVoice.saved(output: output.path, name: "Garden.m4a", readingsRoot: readings,
                                         candidates: [natural, apple], identity: identity) == apple)
        #expect(ReadingResumeVoice.saved(output: output.path, name: "Garden.m4a", readingsRoot: readings,
                                         candidates: [natural], identity: identity) == nil)
    }

    @Test func aReadingsFolderResumesWithTheVoiceItsManifestSaved() throws {
        let folder = root.appendingPathComponent("Readings/1234", isDirectory: true)
        try save(manifest(voice: apple, output: folder.appendingPathComponent("Garden.m4a")), in: folder)
        #expect(ReadingResumeVoice.saved(output: folder.path, name: "Garden.m4a",
                                         readingsRoot: root.appendingPathComponent("Readings"),
                                         candidates: [natural], identity: identity) == apple)
    }

    @Test func printTextNamesTheFileNotTheVoice() throws {
        let folder = root.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let document = ReadableDocument(title: "Garden", sections: [.init(paragraphs: ["Hello there."])])
        let script = ReadingScript(document: document)
        let text = try ReadingPreview.printed(
            script: script, metadata: AudioBookMetadata(title: "Garden", author: nil, language: "en"),
            voiceName: "Natural — Alba (English)", voiceID: natural, output: folder.path, fileName: "Garden.m4a",
            identity: identity(natural), readingsRoot: root.appendingPathComponent("Readings"))
        let lines = text.components(separatedBy: "\n")
        #expect(lines.contains("Voice: Natural — Alba (English) (pocket:en:alba)"))
        #expect(lines.contains { $0.hasPrefix("File: ") && $0.hasSuffix("/Out/Garden.m4a") })
    }
}

@Suite struct ReadingResumeCandidateTests {
    @Test func theNaturalVoiceIsACandidateWhetherOrNotItsPackIsInstalled() throws {
        #expect(ReadingResumeVoice.candidates(language: "en-CA", apple: "ava") == ["pocket:en:alba", "ava"])
        #expect(ReadingResumeVoice.candidates(language: "fr", apple: "amelie") == ["pocket:fr:estelle", "amelie"])
        #expect(ReadingResumeVoice.candidates(language: "de-DE", apple: "anna") == ["anna"])
        // A reading started with Alba is found (its pack may have been removed since; that is told afterwards).
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("holos-candidates-\(UUID().uuidString)")
        let readings = root.appendingPathComponent("Readings", isDirectory: true)
        try FileManager.default.createDirectory(at: readings, withIntermediateDirectories: true)
        let output = root.appendingPathComponent("Garden.m4a")
        let identity = { (voice: String) in "identity-of-\(voice)" }
        let (location, _) = try ReadingOutput.resolve(output: output.path, name: "Garden.m4a",
                                                      identity: identity("pocket:en:alba"), readingsRoot: readings)
        try FileManager.default.createDirectory(at: location.workDirectory, withIntermediateDirectories: true)
        let manifest = ReadingManifest(
            kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion, sourceSHA256: "s",
            voiceIdentifier: "pocket:en:alba", rate: nil, title: "Garden", author: nil, language: "en", comment: "c",
            format: .current, output: output.path, outputSHA256: nil, duration: nil, chapters: [],
            status: "incomplete", parts: [])
        try JSONEncoder().encode(manifest).write(to: location.workDirectory.appendingPathComponent(ReadingManifest.fileName))
        #expect(ReadingResumeVoice.saved(output: output.path, name: "Garden.m4a", readingsRoot: readings,
                                         candidates: ReadingResumeVoice.candidates(language: "en", apple: "ava"),
                                         identity: identity) == "pocket:en:alba")
    }
}

@Suite struct StrictTextDecodingTests {
    @Test func malformedBytesAreRefusedAndAByteOrderMarkIsDropped() {
        #expect(DocumentText.decodeStrictly(Data("Garden\r\nPath".utf8)) == "Garden\nPath")
        #expect(DocumentText.decodeStrictly(Data([0xEF, 0xBB, 0xBF]) + Data("Café".utf8)) == "Café")
        #expect(DocumentText.decodeStrictly(Data([0x47, 0x61, 0xFF, 0x72])) == nil)
        #expect(DocumentText.decodeStrictly(Data([0xEF, 0xBB, 0xBF, 0x47, 0xC3])) == nil)
        #expect(DocumentText.decodeStrictly(Data([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00])) == "Hi")
    }
}

