import FluidAudio
import Foundation
import HolosSynthesis
import Testing
@testable import HolosPocket

/// The addresses the pack's listing and root files are fetched from (offline: nothing is fetched), and the layout the
/// files check assumes, against FluidAudio's own.
@Suite(.serialized) struct PocketAddressTests {
    @Test func everyAddressNamesThePinnedCommitThroughTheRegistry() throws {
        let listing = try PocketSpeechBackend.listingURL("v2.1/english", recursive: true)
        #expect(listing.absoluteString == "https://huggingface.co/api/models/FluidInference/pocket-tts-coreml/tree/"
            + NaturalVoiceModels.revision + "/v2.1/english?recursive=1")
        let root = try PocketSpeechBackend.listingURL("", recursive: false)
        #expect(root.absoluteString.hasSuffix("/tree/" + NaturalVoiceModels.revision))
        let file = try PocketSpeechBackend.fileURL("encoder_recover_pinv.bin")
        #expect(file.absoluteString == "https://huggingface.co/FluidInference/pocket-tts-coreml/resolve/"
            + NaturalVoiceModels.revision + "/encoder_recover_pinv.bin")
        #expect(![listing, root, file].contains { $0.absoluteString.contains("/main") })
    }

    @Test func aConfiguredMirrorIsUsedAsFluidAudiosDownloadsUseIt() throws {
        let (base, repositories) = (ModelRegistry.baseURL, ModelRegistry.repoOverrides)
        defer {
            ModelRegistry.baseURL = base
            ModelRegistry.repoOverrides = repositories
        }
        ModelRegistry.baseURL = "https://mirror.example"
        ModelRegistry.repoOverrides = ["FluidInference/pocket-tts-coreml": "Mirror/pocket-tts-coreml"]
        #expect(try PocketSpeechBackend.listingURL("v2.1/french_24l", recursive: true).absoluteString
            == "https://mirror.example/api/models/Mirror/pocket-tts-coreml/tree/" + NaturalVoiceModels.revision
            + "/v2.1/french_24l?recursive=1")
        #expect(try PocketSpeechBackend.fileURL("encoder_recover_pinv.bin").absoluteString
            == "https://mirror.example/Mirror/pocket-tts-coreml/resolve/" + NaturalVoiceModels.revision
            + "/encoder_recover_pinv.bin")
    }

    @Test func theFilesCheckLooksWhereFluidAudioPutsThePack() throws {
        let base = URL(fileURLWithPath: "/base")
        #expect(PocketSpeechBackend.repositoryFolder(base: base).path
            == base.appendingPathComponent(NaturalVoicePackFiles.repositoryPath).path)
        for pack in NaturalVoicePack.allCases {
            #expect(try PocketSpeechBackend.language(pack).repoSubdirectory
                == NaturalVoicePackFiles.languageSubdirectory(pack))
        }
    }
}
