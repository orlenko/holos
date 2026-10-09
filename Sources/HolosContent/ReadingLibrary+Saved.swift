import Foundation
import HolosCore

extension ReadingLibrary {
    /// The cache of a reading begun before, from the `cache` and `output` paths kept for it, when it is still there
    /// with a reading's manifest: reopened as it is for a resume, whatever cache the reading's settings would name now
    /// (a newer natural voices commit names another), so the pipeline checks it and a refusal names the reading's own
    /// cache. Nil when no paths are given or the cache is gone (the reading starts anew). Not on the main actor.
    public static func savedLocation(cache: String?, output: String?) throws -> ReadingLocation? {
        guard let cache, let output else { return nil }
        let directory = ReadingOutput.fileURL(keepingSpelling: cache, isDirectory: true)
        guard try ReadingOutput.exists(directory),
              ReadingManifest.isReading(directory.appendingPathComponent(ReadingManifest.fileName)) else { return nil }
        return ReadingLocation(workDirectory: directory, output: ReadingOutput.fileURL(keepingSpelling: output))
    }
}
