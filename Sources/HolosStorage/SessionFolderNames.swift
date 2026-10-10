import Foundation

/// Session folder names (`<SESSION-ID>.holos`, docs/meeting/session-format.md §2.1), so no code builds or reads one by hand.
///
/// Two rules answer two questions:
/// - Which session is a folder named after (`parse(folderName:)`): only `<ID>.holos` where ID is an uppercase UUID
///   written as `UUID().uuidString` writes it (8-4-4-4-12 hex digits, A–F uppercase). Session folders are created
///   only so: `SessionArchive.create` names its folder `folderName(for:)` of `UUID().uuidString` and refuses an ID
///   that is not an uppercase UUID, an import names its folder the same way, and `SessionArchive.readManifest`
///   refuses a folder not named `<manifest.id>.holos`. A lowercase or braced UUID, a name with more around the UUID
///   (extra dots, spaces, a leading dot), and any other name parse to nil.
/// - Whether a folder is a session folder at all (`isSessionFolderName`): any name ending in ".holos" after at least
///   one character, so a folder the user renamed ("Budget review.holos") or one left damaged is still listed, found
///   by the ID in its manifest, deletable, and reached through the folder chain without following links. Listings
///   also skip hidden names (`isListedSessionFolderName`).
extension SessionPaths {
    /// The extension of a session folder, without the dot.
    public static let folderExtension = "holos"
    private static let folderSuffix = ".holos"

    /// `<id>.holos`. Like every function here that takes an ID, it does not validate it.
    public static func folderName(for id: String) -> String { id + folderSuffix }

    /// `<root>/<id>.holos`.
    public static func folder(for id: String, in root: URL) -> URL {
        root.appendingPathComponent(folderName(for: id), isDirectory: true)
    }

    /// The session ID a folder name gives, nil unless it is `<uppercase UUID>.holos` (see the rules above).
    public static func parse(folderName name: String) -> String? {
        guard name.hasSuffix(folderSuffix) else { return nil }
        let id = String(name.dropLast(folderSuffix.count))
        return UUID(uuidString: id)?.uuidString == id ? id : nil
    }

    /// Whether `name` is a session folder's, renamed or not: something, then ".holos".
    public static func isSessionFolderName(_ name: String) -> Bool {
        name.count > folderSuffix.count && name.hasSuffix(folderSuffix)
    }

    /// A session folder name a listing shows: `isSessionFolderName`, and not hidden.
    public static func isListedSessionFolderName(_ name: String) -> Bool {
        !name.hasPrefix(".") && isSessionFolderName(name)
    }

    /// `name` without ".holos" (all of it when it does not end so): what a folder whose manifest cannot be read is
    /// called in place of its session ID.
    public static func stem(ofFolderName name: String) -> String {
        name.hasSuffix(folderSuffix) ? String(name.dropLast(folderSuffix.count)) : name
    }
}
