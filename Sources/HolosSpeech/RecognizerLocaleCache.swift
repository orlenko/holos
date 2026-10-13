import HolosCore
import Synchronization

/// Shares known recognizer languages between live dictation and later recognition requests.
///
/// Invariants:
/// 1. Every snapshot update and read holds `storage`'s mutex.
/// 2. An empty backend response retains that backend's last known languages.
final class RecognizerLocaleCache: Sendable {
    private let storage = Mutex(RecognizerLocales.unknown)

    func remember(_ discovered: RecognizerLocales) -> RecognizerLocales {
        storage.withLock { known in
            known = discovered.retainingKnownLocales(from: known)  // invariant 2
            return known
        }
    }
}
