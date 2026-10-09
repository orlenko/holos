import AppKit
import Foundation
@testable import HolosContent
import HolosCore
import HolosSynthesis
import HolosTestSupport
import Synchronization
import Testing
@testable import HolosApp

/// The voice a reading gets (`ReadingVoices.choose`).
@MainActor @Suite struct ReadingVoicesTests {
    private let ava = VoiceDescriptor(id: "ava", name: "Ava (Premium)", language: "en-US", quality: "premium")
    private let amelie = VoiceDescriptor(id: "amelie", name: "Amélie", language: "fr-CA", quality: "default")

    private func choose(fixed: String? = nil, language: String?, saved: ReadingManifest? = nil,
                        installed: Set<NaturalVoicePack>) throws -> VoiceDescriptor {
        let apple = [ava, amelie]
        return try ReadingVoices.choose(
            fixed: fixed, fixedName: nil, language: language, saved: saved, installed: installed, appleVoices: apple,
            bestApple: { tag in apple.first { $0.language.hasPrefix(String(tag.prefix(2))) } },
            appleDefault: { "ava" })
    }

    @Test func automaticPicksTheNaturalVoiceOnceItsPackIsInstalled() throws {
        #expect(try choose(language: "en-US", installed: []).id == "ava")
        #expect(try choose(language: "en-US", installed: [.english]).id == "pocket:en:alba")
        #expect(try choose(language: "fr-CA", installed: [.english]).id == "amelie")
        #expect(try choose(language: "fr-CA", installed: [.english, .french]).id == "pocket:fr:estelle")
        // A reading started with a voice keeps it.
        #expect(try choose(fixed: "ava", language: "en-US", installed: [.english]).id == "ava")
        #expect(try choose(fixed: "pocket:en:george", language: "en", installed: [.english]).id == "pocket:en:george")
    }

    @Test func aNaturalVoiceWhosePackIsMissingSaysWhereToGetIt() {
        let error = #expect(throws: HolosError.self) {
            try choose(fixed: "pocket:fr:estelle", language: "fr", installed: [.english])
        }
        #expect(error?.localizedDescription.contains("The French natural voices are not installed. Download them in "
            + "Settings › Reading, then choose Resume.") == true)
        #expect(throws: HolosError.self) { try choose(fixed: "pocket:en:cosette", language: "en", installed: [.english]) }
    }

    @Test func aReadingFromAnotherCommitOfTheVoicesIsRefusedBeforeItsPackIsAskedFor() throws {
        func manifest(revision: String?) -> ReadingManifest {
            ReadingManifest(kind: ReadingManifest.readingKind, schemaVersion: ReadingManifest.currentSchemaVersion,
                            sourceSHA256: "s", voiceIdentifier: "pocket:fr:estelle", rate: nil, title: "Jardin",
                            author: nil, language: "fr", comment: "c", format: .current, output: "/tmp/Jardin.m4a",
                            outputSHA256: nil, duration: nil, chapters: [], status: "incomplete", parts: [],
                            modelRevision: revision)
        }
        // The French pack is not installed, and installing it would not help: the commit is said first.
        let stale = manifest(revision: "0000000000000000000000000000000000000000")
        let error = #expect(throws: HolosError.self) {
            try choose(fixed: "pocket:fr:estelle", language: "fr", saved: stale, installed: [.english])
        }
        #expect(error?.localizedDescription.contains("another version of the natural voices") == true)
        #expect(error?.localizedDescription.contains("Delete this reading and make it again.") == true)
        // The same commit: the missing pack is what is said.
        let current = manifest(revision: NaturalVoiceModels.revision)
        let missing = #expect(throws: HolosError.self) {
            try choose(fixed: "pocket:fr:estelle", language: "fr", saved: current, installed: [.english])
        }
        #expect(missing?.localizedDescription.contains("natural voices are not installed") == true)
        #expect(try choose(fixed: "pocket:fr:estelle", language: "fr", saved: current, installed: [.french]).id
            == "pocket:fr:estelle")
    }
}
