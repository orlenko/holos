import CryptoKit
import Foundation

/// The files of a natural voice pack as the Hugging Face repository lists them, and the check that a downloaded pack
/// holds every one of them, complete (docs/design.md "Natural voices"). FluidAudio's own check of a pack only looks
/// for its top-level folders, so a download cancelled inside the last model's weights would pass it; this one is what
/// lets a pack move into place.
public enum NaturalVoicePackFiles {
    /// One file of the listing: its path from the repository's root, its size, and, for a file stored with Git LFS,
    /// the SHA-256 of its content.
    public struct Expected: Sendable, Equatable, Decodable {
        public let path: String
        public let size: Int64
        public let sha256: String?

        public init(path: String, size: Int64, sha256: String? = nil) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }

        private struct LFS: Decodable { let oid: String?; let size: Int64? }
        private enum CodingKeys: String, CodingKey { case path, size, type, lfs }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            let lfs = try container.decodeIfPresent(LFS.self, forKey: .lfs)
            size = try lfs?.size ?? container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
            sha256 = lfs?.oid
        }
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

    /// The listed files that are missing under `repositoryFolder`, of another size, or (for LFS files) of other
    /// content: their paths, empty when the pack is complete. A file being resumed (`<file>.partial`) is missing.
    public static func problems(_ expected: [Expected], in repositoryFolder: URL) -> [String] {
        expected.compactMap { file in
            let url = repositoryFolder.appendingPathComponent(file.path)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == file.size else { return file.path }
            if let sha256 = file.sha256, (try? Self.sha256(of: url)) != sha256.lowercased() { return file.path }
            return nil
        }
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
