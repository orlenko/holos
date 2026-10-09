import AppKit

/// The review window's two panes side by side: the speakers on the left, the turn list on the right
/// (docs/meeting/review-window.md §5.10). The speakers pane can be hidden (View ▸ Hide Speakers, ⌥⌘S, the toolbar's
/// Speakers button) once its work is done: it collapses, animated, and the turn list takes its width. Dragging the
/// divider to the left edge hides it too.
@MainActor
final class ReviewPanes: NSSplitViewController {
    /// The speakers pane is narrower than this only when it is hidden.
    static let speakersMinimumWidth: CGFloat = 260
    static let speakersPreferredWidth: CGFloat = 320
    static let listMinimumWidth: CGFloat = 520

    let speakersItem: NSSplitViewItem
    let listItem: NSSplitViewItem
    /// Called when the speakers pane was hidden or shown, by a call here or by a drag of the divider.
    var onSpeakersHiddenChange: ((Bool) -> Void)?
    private var reportedHidden = false

    init(speakers: NSView, list: NSView) {
        let speakersController = NSViewController()
        speakersController.view = speakers
        let listController = NSViewController()
        listController.view = list
        speakersItem = NSSplitViewItem(viewController: speakersController)
        speakersItem.canCollapse = true
        speakersItem.minimumThickness = Self.speakersMinimumWidth
        speakersItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // Hiding it gives its width to the turn list; the window keeps its size.
        speakersItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        listItem = NSSplitViewItem(viewController: listController)
        listItem.minimumThickness = Self.listMinimumWidth
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(speakersItem)
        addSplitViewItem(listItem)
        let preferred = speakers.widthAnchor.constraint(equalToConstant: Self.speakersPreferredWidth)
        preferred.priority = .defaultLow
        preferred.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The speakers pane is hidden.
    var speakersHidden: Bool { speakersItem.isCollapsed }

    /// Hides or shows the speakers pane; animated unless `animated` is false or the person asked for reduced motion.
    func setSpeakersHidden(_ hidden: Bool, animated: Bool) {
        guard hidden != speakersItem.isCollapsed else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, view.window?.isVisible == true {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                speakersItem.animator().isCollapsed = hidden
            }
        } else {
            speakersItem.isCollapsed = hidden
            splitView.adjustSubviews()
        }
        report()
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        report()
    }

    private func report() {
        let hidden = speakersItem.isCollapsed
        guard hidden != reportedHidden else { return }
        reportedHidden = hidden
        onSpeakersHiddenChange?(hidden)
    }
}

/// Which meetings' review windows hide the speakers pane, so a meeting opens again as it was left: once its speakers
/// are named the pane stays out of the way there, while a new meeting still opens with it. Kept in the app's defaults
/// as meeting IDs, the most recent last, at most `limit`.
struct ReviewSpeakersPaneMemory {
    static let key = "reviewSpeakersHiddenMeetings"
    static let limit = 500
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func isHidden(sessionID: String) -> Bool {
        stored.contains(sessionID)
    }

    func setHidden(_ hidden: Bool, sessionID: String) {
        var ids = stored.filter { $0 != sessionID }
        if hidden { ids.append(sessionID) }
        if ids.count > Self.limit { ids.removeFirst(ids.count - Self.limit) }
        if ids != stored { defaults.set(ids, forKey: Self.key) }
    }

    private var stored: [String] { defaults.stringArray(forKey: Self.key) ?? [] }
}
