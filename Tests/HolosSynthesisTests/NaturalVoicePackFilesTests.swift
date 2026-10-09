import Foundation
import HolosCore
import Synchronization
import Testing
@testable import HolosSynthesis

// A pack's files: the listing, what is downloaded, and the checks against the pinned commit.

@Suite final class NaturalVoicePackFilesTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("holos-pack-\(UUID().uuidString)")

    deinit { try? FileManager.default.removeItem(at: folder) }

    @Test func theFilterMatchesFluidAudiosForAPack() {
        for kept in ["v2.1/english/cond_prefill.mlmodelc", "v2.1/english/cond_prefill.mlmodelc/weights/weight.bin",
                     "v2.1/english/constants_bin/alba.safetensors", "v2.1/english/manifest.json",
                     "v2.1/french_24l/flowlm_step.mlmodelc/coremldata.bin"] {
            #expect(NaturalVoicePackFiles.wanted(kept), "\(kept)")
        }
        for skipped in ["v2.1/english/cond_prefill.mlpackage", "v2.1/english/cond_prefill.mlpackage/Manifest.json",
                        "v2.1/english/flowlm_stepv2.mlmodelc/weights/weight.bin", "v2.1/english/cond_step.mlmodelc",
                        "v2.1/english/constants/bos.npy", "v2.1/english/verify.wav", "v2.1/english/.DS_Store",
                        "v2.1/english/flowlm_step_ane.mlmodelc/model.mil"] {
            #expect(!NaturalVoicePackFiles.wanted(skipped), "\(skipped)")
        }
    }

    @Test func aListingGivesItsFilesWithSizesAndChecksums() throws {
        let listing = Data("""
            [{"type":"directory","oid":"x","size":0,"path":"v2.1/english/constants_bin"},
             {"type":"file","oid":"a","size":243,"path":"v2.1/english/cond_prefill.mlmodelc/coremldata.bin",
              "lfs":{"oid":"ABC","size":243,"pointerSize":130}},
             {"type":"file","oid":"b","size":228662,"path":"v2.1/english/cond_prefill.mlmodelc/model.mil"},
             {"type":"file","oid":"c","size":5,"path":"v2.1/english/cond_prefill.mlpackage/Manifest.json"}]
            """.utf8)
        #expect(try NaturalVoicePackFiles.files(fromListing: listing) == [
            .init(path: "v2.1/english/cond_prefill.mlmodelc/coremldata.bin", size: 243, sha256: "ABC"),
            // Not in LFS: its Git blob SHA-1, the listing's `oid`.
            .init(path: "v2.1/english/cond_prefill.mlmodelc/model.mil", size: 228_662, gitBlobSHA1: "b"),
        ])
    }

    @Test func aListingWithAnUnsafePathIsRefused() {
        for path in ["../outside.bin", "v2.1/../../outside.bin", "/etc/passwd", "v2.1//x.bin", "v2.1/./x.bin", ""] {
            let listing = Data("[{\"type\":\"file\",\"oid\":\"a\",\"size\":1,\"path\":\"\(path)\"}]".utf8)
            #expect(throws: HolosError.self, "\(path)") { try NaturalVoicePackFiles.files(fromListing: listing) }
        }
    }

    @Test func aMissingDamagedFileNeedsNothingRemoved() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NaturalVoicePackFiles.remove(["v2.1/english/never-downloaded.bin"], in: folder)
    }

    private func write(_ path: String, _ text: String) throws {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func aCutOffOrDamagedFileIsFound() throws {
        // The listing's checksum of the weights (not the checksum of what is written below).
        let weights = NaturalVoicePackFiles.Expected(
            path: "v2.1/english/flowlm_step.mlmodelc/weights/weight.bin", size: 8,
            sha256: "c5a1ff1da1a1aab6b26f0a2d5fb73e66e4e3cc1a7e4fe5b4eca1c5c2a4d6c8fa")
        // Files outside LFS, checked by their Git blob SHA-1 (of "mil!" and "alb").
        let mil = NaturalVoicePackFiles.Expected(path: "v2.1/english/flowlm_step.mlmodelc/model.mil", size: 4,
                                                 gitBlobSHA1: "93a183fb2d02058ba563d6df6a48719377599bce")
        let voice = NaturalVoicePackFiles.Expected(path: "v2.1/english/constants_bin/alba.safetensors", size: 3,
                                                   gitBlobSHA1: "44db1c1bcac6aef83c0c654e8c1572f1f5184d7a")
        try write(mil.path, "mil!")
        // The weights were cut off: only a partial file is there. The voice has the wrong size.
        try write(weights.path + ".partial", "weig")
        try write(voice.path, "alba")
        #expect(NaturalVoicePackFiles.problems([weights, mil, voice], in: folder) == [weights.path, voice.path])
        // Whole, but other content than the listing's checksum.
        try write(weights.path, "weights?")
        #expect(NaturalVoicePackFiles.problems([weights], in: folder) == [weights.path])
        let real = try NaturalVoicePackFiles.sha256(of: folder.appendingPathComponent(weights.path))
        let right = NaturalVoicePackFiles.Expected(path: weights.path, size: 8, sha256: real.uppercased())
        try write(voice.path, "alb")
        #expect(NaturalVoicePackFiles.problems([right, mil, voice], in: folder).isEmpty)
    }

    @Test func aFileOutsideLFSIsCheckedByContentNotJustSize() throws {
        let mil = NaturalVoicePackFiles.Expected(path: "v2.1/english/mimi_decoder.mlmodelc/model.mil", size: 4,
                                                 gitBlobSHA1: "93a183fb2d02058ba563d6df6a48719377599bce")
        // The same size, other bytes.
        try write(mil.path, "mil?")
        #expect(NaturalVoicePackFiles.problems([mil], in: folder) == [mil.path])
        try write(mil.path, "mil!")
        #expect(NaturalVoicePackFiles.problems([mil], in: folder).isEmpty)
        // Listed without any digest: nothing proves its content, so it is not taken as verified.
        let unknown = NaturalVoicePackFiles.Expected(path: mil.path, size: 4)
        #expect(NaturalVoicePackFiles.problems([unknown], in: folder) == [mil.path])
    }
}
