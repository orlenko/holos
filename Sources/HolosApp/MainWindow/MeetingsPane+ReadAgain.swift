import AppKit
import HolosMeeting

/// When the list reads the catalog. Only this app changes meetings, so with nothing working there is nothing to look
/// for: the list is read when its section shows, when its window becomes key, and when the app changes a meeting. While
/// something works on a meeting its files change without telling the list (a recorder's progress, a command's result),
/// so the list is read every 2 s until that ends.
extension MeetingsPane {
    /// How long the list waits between reads while something works on a meeting.
    static let readAgainAfter: Duration = .seconds(2)

    /// Whether another read is due because something is working.
    var isWaitingToReadAgain: Bool { listState.readAgain != nil }

    /// Something in the app works on a meeting, or the last read found one being worked on (a recorder, a maintenance
    /// lease, a background job in any process).
    var somethingIsWorking: Bool {
        appIsWorking || sessions.contains { summary in
            summary.jobInProgress != nil || [.capturing, .processing, .maintenance].contains(summary.liveness)
        }
    }

    /// Asks for the next read in `readAgainAfter` while something is working and the section shows. Called after each
    /// read, which ends the chain once nothing works, and when the app's work changes, which starts it.
    func readAgainWhileWorking() {
        guard onScreen, listState.readAgain == nil, somethingIsWorking else { return }
        listState.readAgain = Task { [weak self] in
            try? await Task.sleep(for: Self.readAgainAfter)
            guard let self, !Task.isCancelled else { return }
            self.listState.readAgain = nil
            if self.onScreen { self.refresh() }
        }
    }

    func stopReadingAgain() {
        listState.readAgain?.cancel()
        listState.readAgain = nil
    }

    /// Coming back to the window reads the list: a day has passed, or a Review window beside it saved its labels.
    func readWhenTheWindowBecomesKey() {
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard onScreen, let window = notification.object as? NSWindow, window === view.window else { return }
        refresh()
    }
}
