import Foundation
import HolosCore
import HolosMeeting
import HolosStorage
import os

/// The echo catch-up in the app (docs/meeting/online-calls-echo.md §5.11, "Catching up in the app"): calls recorded before the
/// acoustic echo analysis existed, or whose analysis failed, get `voiceislocal session echo-analyze` in the background,
/// newest first, one meeting at a time. The queue (`EchoCatchUpJobs`, `meeting.echo`) is read from the meetings' files
/// at launch and after each meeting is saved, never saved; `BackgroundJobCoordinator` runs it. No setting: it takes
/// about 5 s per hour of audio.
extension HolosAppDelegate {
    private static let echoLog = Logger(subsystem: "ca.orlenko.holos.app", category: "meeting")

    /// Reads the meetings off the main actor (`EchoCatchUpSchedule.scan`) and makes the result the queue. A scan
    /// asked for while one runs runs once more after it.
    func scanEchoCatchUp() {
        guard let root = meeting.controller?.root else { return }
        guard !meeting.echo.scanning else {
            meeting.echo.scanAgain = true
            return
        }
        meeting.echo.scanning = true
        Task { [weak self] in
            let found = await Task.detached { EchoCatchUpSchedule.scan(root: root, profiles: SpeakerProfileStore()) }.value
            guard let self else { return }
            self.meeting.echo.scanning = false
            self.meeting.echo.scanned = true
            // A meeting analysed since the scan read it is checked again before its run starts.
            self.meeting.echo.queue = found
            if !found.isEmpty {
                Self.echoLog.notice("Echo catch-up: \(found.count, privacy: .public) calls miss their echo analysis")
            }
            if self.meeting.echo.scanAgain {
                self.meeting.echo.scanAgain = false
                self.scanEchoCatchUp()
            }
            self.updateEchoStates()
            // The analysis goes first; the automatic jobs held back while the queue was not known go on (or keep
            // waiting for a call it found).
            self.meeting.deep.coordinator?.schedule(catchUpOnly: true)
            if !self.meeting.echo.scanning { self.scheduleBackgroundJobs() }
        }
    }

    /// The Meetings list's badges for queued meetings and its notes for runs that did not finish (the running one
    /// shows as its use of the meeting, `EchoCatchUpSchedule.runningText`).
    func updateEchoStates() {
        let running = meeting.deep.coordinator?.runningSession(of: meeting.echo)
        meeting.meetingsPane?.update(
            echoStates: EchoCatchUpSchedule.stateTexts(meeting.echo.queue, running: running,
                                                       failed: meeting.echo.failed),
            problems: meeting.echo.problems)
    }
}
