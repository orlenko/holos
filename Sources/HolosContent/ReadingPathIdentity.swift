import Darwin
import Foundation
import HolosSynthesis

/// One string for every spelling of one filesystem location, so the locks and cache keys that
/// name a file follow the filesystem's own rules rather than the path's spelling:
/// - the parent folder is its real path (`realpath(3)`: links resolved, "..", and on macOS each
///   component's on-disk case);
/// - the last component (which may not exist yet) is put in Unicode canonical composition and
///   case-folded as `Rule` and the volume's `NameRules` say.
enum ReadingPathIdentity {
    /// How a name's case and Unicode normalization count.
    enum Rule {
        /// For locks: case is folded unless the volume is known to tell names apart by case, and
        /// NFC and NFD spellings are always one, so every spelling that may name one file shares
        /// the lock. On a volume whose rules cannot be told, "Book.m4a" and "book.m4a" (or one
        /// name in NFC and NFD) share a lock, which only serializes them.
        case lock
        /// For render caches and `--resume`: case is folded only when the volume is known to
        /// ignore it, and a name is composed only when the volume is known to treat NFC and NFD
        /// spellings as one (APFS, HFS+), so two spellings share a cache only when they name
        /// one file.
        case exact
    }

    /// How the volume holding a folder compares names; nil where that cannot be told.
    struct NameRules: Equatable {
        /// Whether "Book" and "book" are two names.
        var caseSensitive: Bool?
        /// Whether a name's NFC and NFD spellings name one file.
        var equatesNormalization: Bool?
    }

    typealias VolumeQuery = (String) -> NameRules

    /// The identity of the file `url` names, its path spelled as the URL holds it: as typed for
    /// a `RawFilePath` URL (what `ReadingOutput` gives), decomposed for one Foundation made from a
    /// path string (see `RawFilePath`).
    static func key(_ url: URL, _ rule: Rule = .lock, volume: VolumeQuery = volumeRules) -> String {
        key(path: RawFilePath.standardized(url.path), rule, volume: volume)
    }

    /// The identity of `path`, spelled as given.
    static func key(path: String, _ rule: Rule = .lock, volume: VolumeQuery = volumeRules) -> String {
        // An existing path resolves whole, so a link in the last component is followed too.
        let resolved = realPath(path) ?? path
        let name = (resolved as NSString).lastPathComponent
        let parentPath = (resolved as NSString).deletingLastPathComponent
        let parent = realPath(parentPath)
            ?? URL(fileURLWithPath: parentPath).standardizedFileURL.resolvingSymlinksInPath().path
        let rules = volume(parent)
        let (keepsCase, composes) = switch rule {
        case .lock: (rules.caseSensitive == true, true)
        case .exact: (rules.caseSensitive != false, rules.equatesNormalization == true)
        }
        let folded = normalizedName(name, caseSensitive: keepsCase, composed: composes)
        return parent == "/" ? "/" + folded : parent + "/" + folded
    }

    /// `name` as the volume compares names: composed when `composed`, and case-folded unless
    /// `caseSensitive`. A name not composed keeps its spelling as given.
    static func normalizedName(_ name: String, caseSensitive: Bool, composed: Bool = true) -> String {
        let spelled = composed ? name.precomposedStringWithCanonicalMapping : name
        guard !caseSensitive else { return spelled }
        let folded = spelled.folding(options: [.caseInsensitive], locale: nil)
        return composed ? folded.precomposedStringWithCanonicalMapping : folded
    }

    /// Whether the volume holding `folder` tells names apart by case; false when unknown.
    static func caseSensitive(_ folder: String) -> Bool {
        volumeCaseSensitivity(folder) ?? false
    }

    /// How the volume holding `folder` compares names, as far as it can be told.
    static func volumeRules(_ folder: String) -> NameRules {
        NameRules(caseSensitive: volumeCaseSensitivity(folder),
                  equatesNormalization: volumeEquatesNormalization(folder))
    }

    /// Whether the volume holding `folder` tells names apart by case, as the volume reports it;
    /// nil when that cannot be told.
    static func volumeCaseSensitivity(_ folder: String) -> Bool? {
        let values = try? URL(fileURLWithPath: folder, isDirectory: true)
            .resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames
    }

    /// Whether the volume holding `folder` treats a name's NFC and NFD spellings as one file:
    /// true for APFS and HFS+ (by their format, `statfs`'s `f_fstypename`); nil for any other
    /// or when it cannot be told (a network share may keep the bytes as given).
    static func volumeEquatesNormalization(_ folder: String) -> Bool? {
        guard let type = fileSystemType(folder) else { return nil }
        return normalizationInsensitiveTypes.contains(type) ? true : nil
    }

    static let normalizationInsensitiveTypes: Set<String> = ["apfs", "hfs"]

    /// The format name of the volume holding `path` ("apfs", "hfs", "smbfs", "exfat"), or nil.
    static func fileSystemType(_ path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: &info.f_fstypename) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }.lowercased()
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// Which file a path named at one moment (see `ExclusivePublisher.FileIdentity`).
public typealias ReadingFileIdentity = ExclusivePublisher.FileIdentity
