import CryptoKit
import Foundation

/// The files of a natural voice pack as the Hugging Face repository lists them, and the check that a downloaded pack
/// holds every one of them, complete (docs/design.md "Natural voices"). FluidAudio's own check of a pack only looks
/// for its top-level folders, so a download cancelled inside the last model's weights would pass it; this one is what
/// lets a pack move into place.
public enum NaturalVoicePackFiles {
    /// One file of the listing: its path from the repository's root, its size, and its content's digest: the SHA-256
    /// of a file stored with Git LFS, else the Git blob SHA-1 the listing gives (`sha1("blob <size>\0" + content)`).
    /// The listing is read at the pinned commit, so both digests are the commit's.
    public struct Expected: Sendable, Equatable, Decodable {
        public let path: String
        public let size: Int64
        public let sha256: String?
        public let gitBlobSHA1: String?

        public init(path: String, size: Int64, sha256: String? = nil, gitBlobSHA1: String? = nil) {
            self.path = path
            self.size = size
            self.sha256 = sha256
            self.gitBlobSHA1 = gitBlobSHA1
        }

        private struct LFS: Decodable { let oid: String?; let size: Int64? }
        private enum CodingKeys: String, CodingKey { case path, size, type, lfs, oid }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            let lfs = try container.decodeIfPresent(LFS.self, forKey: .lfs)
            size = try lfs?.size ?? container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
            sha256 = lfs?.oid
            // An LFS entry's `oid` is the pointer file's; its content is checked by the SHA-256 above.
            gitBlobSHA1 = lfs == nil ? try container.decodeIfPresent(String.self, forKey: .oid) : nil
        }
    }

    /// Where FluidAudio keeps the repository under a pack's base folder.
    public static let repositoryPath = "Models/pocket-tts"

    /// The pack's folder in the repository ("v2.1/english").
    public static func languageSubdirectory(_ pack: NaturalVoicePack) -> String { "v2.1/" + pack.fluidLanguage }

    /// The files of each model the voices load that must be there, and not empty.
    static let modelFiles = ["coremldata.bin", "model.mil", "weights/weight.bin"]

    /// A cheap look (no hashing) at an installed pack under `base`: every model the voices load has its files, and
    /// every voice offered in the pack its prompt, none empty. A pack whose files were deleted or cut since it was
    /// installed fails it, and is then checked and repaired by setup.
    public static func looksComplete(base: URL, pack: NaturalVoicePack) -> Bool {
        let folder = base.appendingPathComponent(repositoryPath).appendingPathComponent(languageSubdirectory(pack))
        let files = requiredModels.flatMap { model in modelFiles.map { "\(model)/\($0)" } }
            + NaturalVoiceCatalog.offered.filter { $0.pack == pack }.map { "constants_bin/\($0.name).safetensors" }
        return files.allSatisfy { path in
            guard let attributes = try? FileManager.default.attributesOfItem(
                      atPath: folder.appendingPathComponent(path).path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular else { return false }
            return ((attributes[.size] as? NSNumber)?.int64Value ?? 0) > 0
        }
    }

    /// Files at the repository's root a pack also needs: the 24-layer packs' voice-clone reprojection, which
    /// FluidAudio otherwise fetches from the moving `main` each time it loads such a pack without it.
    public static func rootFiles(for pack: NaturalVoicePack) -> [String] {
        pack == .french ? ["encoder_recover_pinv.bin"] : []
    }

    /// One entry of the repository's tree listing (`/api/models/<repo>/tree/<revision>/<path>?recursive=1`).
    struct Entry: Decodable { let type: String }

    /// The files of a listing (its directories left out), filtered by `wanted`.
    public static func files(fromListing data: Data) throws -> [Expected] {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        let files = try JSONDecoder().decode([Expected].self, from: data)
        return zip(entries, files).compactMap { entry, file in
            entry.type == "file" && wanted(file.path) ? file : nil
        }
    }

    /// The Core ML models the voices load (FluidAudio's fp16 GPU placement), and the constants folder.
    static let requiredModels: Set<String> = [
        "cond_prefill.mlmodelc", "flowlm_step.mlmodelc", "flow_decoder_fused.mlmodelc", "mimi_decoder.mlmodelc",
    ]

    /// Whether a path of the repository (a file or a folder) is downloaded, as FluidAudio 0.17.1 filters a pack: not
    /// `.mlpackage` sources, not the `constants/` intermediates, not a model the voices do not load, not `.DS_Store`
    /// or `verify.wav`.
    public static func wanted(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        guard let last = components.last, last != ".DS_Store", last != "verify.wav" else { return false }
        for component in components {
            if component.hasSuffix(".mlpackage") || component == "constants" { return false }
            if component.hasSuffix(".mlmodelc") && !requiredModels.contains(component) { return false }
        }
        return true
    }

    /// The listed files that are missing under `repositoryFolder`, of another size, or of other content (their SHA-256,
    /// or their Git blob SHA-1, differs from the listing's), or listed without a digest: their paths, empty when the
    /// pack is complete. A file being resumed (`<file>.partial`) is missing.
    public static func problems(_ expected: [Expected], in repositoryFolder: URL) -> [String] {
        expected.compactMap { file in
            let url = repositoryFolder.appendingPathComponent(file.path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == file.size else { return file.path }
            if let sha256 = file.sha256 {
                return (try? Self.sha256(of: url)) == sha256.lowercased() ? nil : file.path
            }
            if let blob = file.gitBlobSHA1 {
                return (try? Self.gitBlobSHA1(of: url, size: file.size)) == blob.lowercased() ? nil : file.path
            }
            // Nothing to check its content against: not taken as verified.
            return file.path
        }
    }

    /// Git's object name of the file's content: SHA-1 of "blob <size>\0" followed by the bytes.
    static func gitBlobSHA1(of url: URL, size: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(size)\u{0}".utf8))
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
