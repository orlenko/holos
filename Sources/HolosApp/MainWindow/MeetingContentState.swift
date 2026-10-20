import AppKit
import HolosMeeting

/// The transcript and review share one meeting screen.
///
/// Invariants:
/// 1. A screen has at most one embedded review.
/// 2. A review remains owned until its closing path saves pending edits.
/// 3. A refused review close cancels the pending request to close its host.
/// 4. Only the latest navigation survives a pending save; refusal or other navigation cancels it.
@MainActor
final class MeetingContentState {
    var reader: LiveTranscriptReader
    var review: ReviewWindow?
    var requestedReview = false
    let progress = MeetingProgressView()
    var closeMainWindow = false
    var afterClose: (() -> Void)?
    let more = MeetingActionsButton()

    init(directory: URL) { reader = LiveTranscriptReader(session: directory) }
}

extension MeetingsPane {
    func sectionWindowDidBecomeKey() {
        live?.embeddedReview?.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification,
                                                              object: view.window))
    }

    func sectionWindowDidResignKey() {
        live?.embeddedReview?.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification,
                                                              object: view.window))
    }

    func sectionShouldClose() -> Bool {
        guard let review = live?.embeddedReview else { return true }
        live?.contentState.afterClose = nil
        live?.contentState.closeMainWindow = true
        guard review.windowShouldClose(review.window) else { return false }
        live?.contentState.closeMainWindow = false
        review.startClosing()
        return true
    }

    func reviewSurfaceClosed() {
        let afterClose = live?.contentState.afterClose
        let closeMainWindow = live?.contentState.closeMainWindow == true
        let window = live?.embeddedReview?.window ?? view.window
        showList()
        if closeMainWindow, live == nil { window?.performClose(nil) }
        else if live == nil { afterClose?() }
    }
}

extension MainWindowController {
    @objc func toggleSpeakers(_ sender: Any?) { meetingReview?.toggleSpeakers(sender) }
    @objc func toggleShortInterjections(_ sender: Any?) { meetingReview?.toggleShortInterjections(sender) }
    @objc func restoreDeletedWords(_ sender: NSMenuItem) { meetingReview?.restoreDeletedWords(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSpeakers(_:))?, #selector(toggleShortInterjections(_:))?, #selector(restoreDeletedWords(_:))?:
            return meetingReview?.validateMenuItem(item) ?? false
        default: return true
        }
    }
}

extension LiveMeetingViewController {
    var embeddedReview: ReviewWindow? { contentState.review }

    func embedReview(_ review: ReviewWindow, onClose: @escaping () -> Void) -> Bool {
        guard contentState.review == nil, let window = view.window,
              let body = review.surface.embed(in: window, onClose: onClose) else { return false }
        stop()
        contentState.review = review // invariant 1
        review.surface.onCloseRefused = { [weak contentState] in
            contentState?.closeMainWindow = false
            contentState?.afterClose = nil
        }
        review.panes.listItem.minimumThickness = 280
        if view.bounds.width < 800 {
            let onChange = review.panes.onSpeakersHiddenChange
            review.panes.onSpeakersHiddenChange = nil
            review.panes.setSpeakersHidden(true, animated: false)
            review.panes.onSpeakersHiddenChange = onChange
            review.refreshSpeakersButton()
        }
        let bar = NSStackView(views: [backButton, titleLabel, NSView(), statusLabel, contentState.progress, contentState.more])
        bar.spacing = 10
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.documentView = body
        body.translatesAutoresizingMaskIntoConstraints = false
        let root = NSStackView(views: [bar, scroll])
        root.orientation = .vertical
        root.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 0, right: 16)
        root.spacing = 8
        root.alignment = .leading
        let fitWidth = body.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        fitWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            scroll.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            body.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            body.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
            body.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor),
            fitWidth,
        ])
        view = root
        return true
    }
}

@MainActor
final class MeetingActionsButton: NSButton {
    var makeMenu: (() -> NSMenu?)?

    init() {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        imagePosition = .imageOnly
        bezelStyle = .push
        toolTip = "More meeting actions"
        setAccessibilityLabel("More meeting actions")
        target = self
        action = #selector(openMenu)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func openMenu() {
        makeMenu?()?.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self)
    }
}
