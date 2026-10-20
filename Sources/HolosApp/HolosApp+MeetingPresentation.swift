import AppKit

extension HolosAppDelegate {
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
