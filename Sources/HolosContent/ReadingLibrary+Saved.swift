import Foundation
import HolosCore

extension ReadingLibrary {
    /// The cache of a reading begun before (its entry's `cache` and `output`), when it is still there with this
    /// app's manifest: reopened as it is for a resume, whatever cache the reading's settings would name now (a newer
    /// natural voices commit names another), so the pipeline checks it and a refusal names the reading's own cache,
    /// which Delete removes. Nil when the entry names none or it is gone (the reading starts anew). Not on the main
    /// actor.
    public static func savedLocation(cache: String?, output: String?) throws -> ReadingLocation? {
        guard let cache, let output else { return nil }
        let directory = ReadingOutput.fileURL(keepingSpelling: cache, isDirectory: true)
        guard try ReadingOutput.exists(directory),
              ReadingManifest.isReading(directory.appendingPathComponent(ReadingManifest.fileName)) else { return nil }
        return ReadingLocation(workDirectory: directory, output: ReadingOutput.fileURL(keepingSpelling: output))
    }
}
