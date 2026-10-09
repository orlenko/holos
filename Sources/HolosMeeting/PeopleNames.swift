import Darwin
import Foundation
import HolosCore
import HolosStorage

/// People's names (the People section) for dictation, whose capitals a pause keeps (`DictationSeams`), as live
/// dictation and Run Again both read them: before each dictation, so a person added or renamed counts from the next
/// one. The people store is read again only when its file changed (its inode, size, and modification and
/// status-change times), since it also holds voice samples and may be large; one `stat` otherwise.
public final class PeopleNames {
    private let store: SpeakerProfileStore
    private var stamp: [Int64]?
    private var read = false
    private var cached: [String] = []

    public init(store: SpeakerProfileStore = SpeakerProfileStore()) {
        self.store = store
    }

    /// The names, sorted; empty when there are no people or the store cannot be read.
    public func current() -> [String] {
        // The stamp is taken before the read: a write in between makes the next call read again.
        let now = Self.stamp(of: store.databaseURL)
        if read, now == stamp { return cached }
        cached = VoiceProfileService.profileNames(store: store).values.sorted()
        stamp = now
        read = true
        return cached
    }

    static func stamp(of url: URL) -> [Int64]? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return [Int64(info.st_ino), info.st_size, Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }
}
