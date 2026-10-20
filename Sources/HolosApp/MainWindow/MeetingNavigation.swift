import Foundation

extension MeetingsPane {
    /// A different meeting waits for the current review's save gate. Only its latest destination survives.
    func prepareMeetingNavigation(to sessionID: String, replay: @escaping () -> Void) -> Bool {
        guard let shown = live else { return true }
        guard shown.sessionID != sessionID else { shown.contentState.afterClose = nil; return true }
        if let review = shown.embeddedReview, !review.isClosing {
            shown.contentState.closeMainWindow = false
            shown.contentState.afterClose = replay
            if review.windowShouldClose(review.window) { review.startClosing() }
            return false
        }
        showList()
        return live == nil
    }
}
