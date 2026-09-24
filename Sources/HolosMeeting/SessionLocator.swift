import Darwin
import Foundation
import HolosCore

/// Turns what a user typed for `<session>` in a command into a session folder (docs/meeting-design.md §5.7).
public enum SessionLocator {
    /// A path to a .holos folder, or a session UUID under `root`.
    ///
    /// Details:
    /// - A UUID (any case) that is not written as a path (no "/", no ".holos" extension, not starting with "~" or
    ///   ".") names `<root>/<UPPERCASE UUID>.holos`, which must exist.
    /// - Anything else is a path: "~" is expanded, a relative path is taken from the current folder, and the result
    ///   must be an existing folder named `<something>.holos`. A symbolic link in place of the session folder itself
    ///   is refused, as every session operation refuses it; folders above it may be links (as `/var` is on macOS).
    /// - The folder is not otherwise checked here: reading its manifest reports a folder that is not a session.
    /// Throws `HolosError.invalidInput` with what to type instead.
    public static func resolve(_ text: String, root: URL = HolosPaths.sessions) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw HolosError.invalidInput("Name a session: the path to its .holos folder or its session ID.")
        }
        if !looksLikePath(trimmed), let uuid = UUID(uuidString: trimmed) {
            let id = uuid.uuidString
            let url = root.appendingPathComponent("\(id).holos", isDirectory: true).standardizedFileURL
            switch try kind(of: url) {
            case .folder:
                return url
            case .link:
                throw HolosError.invalidInput("\(url.path) is a symbolic link, not a session folder.")
            case .other:
                throw HolosError.invalidInput("\(url.path) is not a session folder.")
            case .missing:
                throw HolosError.invalidInput(
                    "There is no session \(id) in \(root.path). Give the path to its .holos folder instead.")
            }
        }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
            .standardizedFileURL
        guard url.pathExtension == "holos" else {
            throw HolosError.invalidInput(
                "\(trimmed) is not a session: give the path to a .holos folder or a session ID.")
        }
        switch try kind(of: url) {
        case .folder:
            return url
        case .link:
            throw HolosError.invalidInput("\(url.path) is a symbolic link; give the session folder itself.")
        case .other:
            throw HolosError.invalidInput("\(url.path) is not a folder.")
        case .missing:
            throw HolosError.invalidInput("There is no session folder at \(url.path).")
        }
    }

    // MARK: - Private

    private enum Kind { case folder, link, other, missing }

    /// Whether the text was written as a path rather than a bare session ID.
    private static func looksLikePath(_ text: String) -> Bool {
        text.contains("/") || text.hasPrefix("~") || text.hasPrefix(".") || text.lowercased().hasSuffix(".holos")
    }

    /// What is at `url`, without following a symbolic link at its last component. Throws `HolosError.io` when it
    /// cannot be looked at (for example, a folder on the way is not readable).
    private static func kind(of url: URL) throws -> Kind {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            let code = errno
            if code == ENOENT || code == ENOTDIR { return .missing }
            throw HolosError.io("Cannot look at \(url.path): \(String(cString: strerror(code))).")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .folder
        case S_IFLNK: return .link
        default: return .other
        }
    }
}
