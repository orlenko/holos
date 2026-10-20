import AppKit

extension HolosAppDelegate {
    func prepareMeetingReview(sessionID: String, directory: URL, name: String, fallBackToMeetings: Bool) -> Bool {
        showMeetingsWindow(selecting: sessionID)
        guard let pane = meeting.meetingsPane, pane.prepareMeetingNavigation(to: sessionID, replay: { [weak self] in
            self?.openReview(sessionID: sessionID, directory: directory, name: name,
                             fallBackToMeetings: fallBackToMeetings)
        }) else { return false }
        pane.showLive(sessionID: sessionID, directory: directory)
        return true
    }

    /// Every meeting opens in the main window, including a review opened from a menu-bar offer.
    func presentMeetingReview(_ review: ReviewWindow) {
        let pane = meeting.meetingsPane
        guard pane?.canPresentReview == true, pane?.activeMeetingID == review.sessionID,
              pane?.installReview(review) == true else {
            if pane?.activeMeetingID == review.sessionID { pane?.live?.contentState.requestedReview = false }
            review.startClosing()
            return
        }
        review.show()
    }
}
