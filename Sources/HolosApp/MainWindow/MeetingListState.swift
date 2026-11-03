import AppKit
import HolosCore
import HolosMeeting

/// Snapshots for the list and open meeting.
///
/// Invariants:
/// 1. A catalog read publishes its progress together with its meeting rows.
/// 2. At most one rename waits to start (`pendingRename`); a new click, a double-click or a row's action cancels it; it
///    does not start once a meeting is open, the list has lost the keyboard, or the window is no longer key.
@MainActor
final class MeetingListState {
    let filesCache = TranscriptFilesCache()
    /// The next read while something works on a meeting (`readAgainWhileWorking`).
    var readAgain: Task<Void, Never>?
    /// The list reads the catalog often while something works on a meeting (`SessionCatalogCache`).
    let catalogCache = SessionCatalogCache()
    var progress: [String: PostProcessingProgress] = [:]
    var onStartRecording: (() -> Void)?
    /// The meeting selected alone when the mouse went down, and the rename a click on its name waits to start.
    var renameCandidate: String?
    var pendingRename: Task<Void, Never>?
    /// Where Copy Path puts the meeting's path (tests use a pasteboard of their own).
    var pasteboard = NSPasteboard.general

    func cancelPendingRename() {
        pendingRename?.cancel()
        pendingRename = nil
    }
}
