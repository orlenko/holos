import Darwin
import FluidAudio
import Foundation
import HolosCore

/// Ultra is installed only by setup. Each CLI invocation owns its FluidAudio configuration.
public enum ParakeetModels {
    public static var directory: URL {
        HolosPaths.models.appendingPathComponent("parakeet-ultra@\(ParakeetPins.revision.prefix(12))", isDirectory: true)
    }

    /// Checks the pinned files without loading the model or contacting the network.
    public static func isInstalled() throws -> Bool { try verified(directory) }

    static func repo(in directory: URL) -> URL {
        directory.appendingPathComponent(Repo.parakeetUltra.folderName, isDirectory: true)
    }

    /// loadLocal also looks for an optional CTC head. Accept only the pinned model tree.
    static func verified(_ directory: URL, pinned: [PinnedFile] = ParakeetPins.files) throws -> Bool {
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        let folder = repo(in: directory)
        guard !pinned.isEmpty, FluidModels.readMarker(in: folder, revision: ParakeetPins.revision) == .matches else { return false }
        return try ModelTreeDigest.manifest(of: folder) == pinned
    }

    public static func setUp(force: Bool, progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = directory
        try await FluidModels.withStagingFolder(for: directory, setupFlag: "--parakeet") { partial in
            if !force, (try? verified(directory)) == true {
                _ = try AsrModels.loadLocal(from: repo(in: directory), version: .ultra)
                return
            }
            ModelRegistry.revisionOverrides[Repo.parakeetUltra.remotePath] = ParakeetPins.revision
            ModelHub.offlineMode = false
            defer { ModelHub.offlineMode = true }
            try await ModelHub.download(.parakeetUltra, to: partial) {
                // ModelHub reserves the second half of its range for model loading.
                progress(min(0.9, 1.8 * $0.fractionCompleted))
            }
            try Task.checkCancellation()
            guard try verified(partial) else {
                throw HolosError.incomplete("The Parakeet Ultra download differs from its pinned revision.")
            }
            _ = try AsrModels.loadLocal(from: repo(in: partial), version: .ultra)
            try Task.checkCancellation()
            try FluidModels.publish(partial, to: directory)
            progress(1)
        }
    }
}
