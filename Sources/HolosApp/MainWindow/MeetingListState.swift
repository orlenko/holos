import HolosCore
import HolosMeeting

/// Snapshots for the list and open meeting.
///
/// Invariants:
/// 1. A catalog read publishes its progress together with its meeting rows.
@MainActor
final class MeetingListState {
    let filesCache = TranscriptFilesCache()
    var progress: [String: PostProcessingProgress] = [:]
    var onStartRecording: (() -> Void)?
}
