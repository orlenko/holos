import Darwin
import Foundation
import HolosCore
import HolosStorage
import Synchronization

/// People's names (the People section) for dictation, whose capitals a pause keeps (`DictationSeams`), as live
/// dictation and Run Again both read them. The people store also holds voice samples and may be large (up to 64 MiB),
/// so it is never read on the caller's thread: `current()` answers at once with the names last read and asks for a
/// refresh in the background, which reads the store again only when its file changed (its inode, size, and
/// modification and status-change times), and then decodes the names alone. A person added or renamed counts from the
/// dictation after the refresh that sees it; the app also refreshes at launch, so the first dictation has them.
public final class PeopleNames: Sendable {
    private struct State {
        var names: [String] = []
        /// The file the names were read from; nil before the first read.
        var stamp: [Int64]??
        var refreshing = false
    }

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "ca.orlenko.holos.people-names", qos: .utility)
    private let stamp: @Sendable () -> [Int64]?
    private let read: @Sendable () -> [String]

    /// The names in `store`.
    public convenience init(store: SpeakerProfileStore = SpeakerProfileStore()) {
        let url = store.databaseURL
        self.init(stamp: { PeopleNames.stamp(of: url) }, read: { PeopleNames.names(at: url) })
    }

    /// `stamp` tells a changed store from the one read before (nil: no store); `read` reads the names, sorted. Both
    /// run in the background, one call at a time.
    init(stamp: @escaping @Sendable () -> [Int64]?, read: @escaping @Sendable () -> [String]) {
        self.stamp = stamp
        self.read = read
    }

    /// The names last read, sorted (empty before the first read ends); asks for a refresh. Never waits.
    public func current() -> [String] {
        refresh()
        return state.withLock { $0.names }
    }

    /// Reads the names again in the background when the store changed since the last read; one refresh at a time.
    public func refresh() {
        let start = state.withLock { state -> Bool in
            guard !state.refreshing else { return false }
            state.refreshing = true
            return true
        }
        guard start else { return }
        queue.async { [self] in
            let now = stamp()
            let known = state.withLock { $0.stamp }
            // The stamp is taken before the read: a write in between makes the next refresh read again.
            let names = known.map { $0 == now } == true ? nil : (now == nil ? [] : read())
            state.withLock { state in
                if let names {
                    state.names = names
                    state.stamp = .some(now)
                }
                state.refreshing = false
            }
        }
    }

    /// Refreshes, waits for it, and returns the names: for a command-line run, which has no earlier read.
    public func refreshed() async -> [String] {
        refresh()
        await settled()
        return state.withLock { $0.names }
    }

    /// Waits until the refreshes asked for so far ended.
    func settled() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    static func stamp(of url: URL) -> [Int64]? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return [Int64(info.st_ino), info.st_size, Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
    }

    /// The people's names in the store at `url`, sorted, without decoding their voice samples; empty when it cannot be
    /// read.
    static func names(at url: URL) -> [String] {
        struct Store: Decodable {
            struct Person: Decodable { var displayName: String }
            var profiles: [Person]
        }
        guard let data = try? AtomicFile.readIfPresent(url, maxBytes: 64 << 20),
              let store = try? HolosJSON.decoder().decode(Store.self, from: data) else { return [] }
        return store.profiles.map(\.displayName).sorted()
    }
}
