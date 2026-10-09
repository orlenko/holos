import AppKit

/// The turn list's scroll view: reports scrolling the reader does (wheel, trackpad, scroller), which pauses following
/// playback for a few seconds (`ReviewFollow`); scrolling done by the window is not reported.
final class TurnScrollView: NSScrollView {
    var onUserScroll: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }
}
