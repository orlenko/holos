import Foundation
@testable import HolosMeeting
import Testing

// StateChangeTracker (docs/meeting-design.md §5.10): the review window redraws its footer on every playback state
// change. Helpers are prefixed `tracker`.

/// The review player's states, as the window sees them.
private enum TrackerPlayback: Equatable {
    case loading
    case ready
    case unavailable(String)

    var isReady: Bool { self == .ready }
}

@Test func trackerReportsEveryPlaybackStateTransition() {
    var tracker = StateChangeTracker<TrackerPlayback>()
    // Whether each successive state is reported as a change.
    let states: [TrackerPlayback] = [
        .loading, .loading,
        // The first load fails: neither state is ready, yet the footer must show why playback is off.
        .unavailable("Playback is off: unreadable."), .unavailable("Playback is off: unreadable."),
        // Another reason is another notice.
        .unavailable("Audio deleted; playback is off."),
        .loading, .ready, .ready,
    ]
    var changes: [Bool] = []
    for state in states { changes.append(tracker.update(state)) }
    #expect(changes == [true, false, true, false, true, true, true, false])
    #expect(tracker.shown == .ready)
    #expect(TrackerPlayback.loading.isReady == TrackerPlayback.unavailable("x").isReady,
            "A readiness flag alone misses the change from loading to off.")
}
