import AppKit
import HolosCore
import HolosMeeting

/// Snapshots for the list and open meeting.
///
/// Invariants:
/// 1. A catalog read publishes its progress together with its meeting rows.
/// 2. At most one rename waits to start (`pendingRename`); a new click or a double-click cancels it, and it does not
///    start once a meeting is open.
@MainActor
final class MeetingListState {
    let filesCache = TranscriptFilesCache()
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
