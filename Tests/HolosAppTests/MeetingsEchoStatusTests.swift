import AppKit
import Foundation
import HolosCore
import HolosMeeting
import Testing
@testable import HolosApp

/// What the Meetings list shows of the echo catch-up (docs/meeting-design.md §5.11, "Catching up in the app"), in the
/// real main window laid out offscreen (never shown): a queued meeting's badge, the running one's use of the meeting
/// in its place, and a run that failed in this launch as a badge and the selected meeting's status line. No process is
/// started; the pane is fed what the app delegate would give it.
@MainActor
struct MeetingsEchoStatusTests {
    private static func call(_ id: String, hoursAgo: Double) -> SessionSummary {
        SessionSummary(id: id, directory: URL(fileURLWithPath: "/\(id).holos"), name: "Call \(id)",
                       createdAt: Date().addingTimeInterval(-hoursAgo * 3600), source: .microphoneAndSystem,
                       state: .complete, manifestStatus: "complete", transcriptID: "T", speakerState: .labelled,
                       liveness: .exited)
    }

    @Test(.timeLimit(.minutes(1)))
    func queuedRunningAndFailedEchoRunsShowInTheList() throws {
        let (_, pane) = try LiveMeetingViewTests.meetings(size: SettingsEmbeddingTests.sizes[0])
        let first = Self.call("A", hoursAgo: 1), second = Self.call("B", hoursAgo: 2)
        // Selected once the list is read; the list is given here, as the catalog read would give it.
        pane.select(sessionID: first.id)
        pane.show([first, second], people: [:], freeBytes: nil)
        #expect(pane.badges(second, livePhase: nil).isEmpty)

        pane.update(echoStates: ["A": EchoCatchUpSchedule.queuedText, "B": EchoCatchUpSchedule.queuedText],
                    problems: [:])
        #expect(pane.badges(second, livePhase: nil) == [.init("Echo removal queued", .progress)])

        // A runs: its use of the meeting says so (`beginUsing`), and it is no longer queued.
        pane.update(running: ["A": EchoCatchUpSchedule.runningText])
        pane.update(echoStates: ["B": EchoCatchUpSchedule.queuedText], problems: [:])
        #expect(pane.badges(first, livePhase: nil) == [.init("Removing echo…", .progress)])
        #expect(pane.statusText.contains("Removing echo…"))

        // A failed: a warning badge, and the status line says why and when it is tried again.
        pane.update(running: [:])
        pane.update(echoStates: ["B": EchoCatchUpSchedule.queuedText],
                    problems: ["A": .failed("The audio is damaged")])
        #expect(pane.badges(first, livePhase: nil) == [.init("Echo not removed", .warning)])
        #expect(pane.statusText.contains("The call's echo was not removed from this meeting. The audio is damaged."))
        #expect(pane.statusText.contains("next time it starts"))

        // Saved with something left behind: the status line says so, without the warning badge.
        pane.update(echoStates: [:], problems: ["A": .partial("The transcript files could not be rewritten.")])
        #expect(pane.badges(first, livePhase: nil).isEmpty)
        #expect(pane.statusText.contains("The transcript files could not be rewritten."))
    }
}
