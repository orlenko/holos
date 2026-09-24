import Foundation
import HolosCore
import HolosStorage

/// The vocabulary hand-off file the app writes for `holos record start --vocabulary-file` (docs/meeting-design.md
/// §4.12).
public enum VocabularyFile {
    /// Reads the vocabulary from `url` and deletes the file, since it holds private names: once it is opened and
    /// verified as a regular file (not followed if it is a symbolic link), it is unlinked whether or not it could be
    /// used. A folder, symbolic link, or other entry in its place is refused and never touched; nothing is ever
    /// removed recursively (`AtomicFile.readAndRemove`). Throws `HolosError.invalidInput` for a missing, refused,
    /// or unusable file.
    public static func consume(_ url: URL) throws -> [String] {
        guard let data = try AtomicFile.readAndRemove(url, maxBytes: 1 << 20) else {
            throw HolosError.invalidInput("The vocabulary file \(url.path) does not exist.")
        }
        guard let vocabulary = try? HolosJSON.decoder().decode(MeetingVocabulary.self, from: data),
              vocabulary.schemaVersion == 1 else {
            throw HolosError.invalidInput("The vocabulary file is not a Holos vocabulary (schemaVersion 1 with strings).")
        }
        return vocabulary.strings
    }
}
