import AppKit

/// Views (buttons, mostly) in a row that wraps onto more rows when the width runs out, so a row of actions never holds
/// the main window wider than its narrowest (`MainWindowController.contentMinimumWidth`). Give it a width (constrain
/// it to its container's): its height follows from the rows the views take at that width. Hidden views take no room.
@MainActor
final class WrappingRowView: NSView {
    let spacing: CGFloat
    let rowSpacing: CGFloat
    private(set) var views: [NSView]
    private var laidOutHeight: CGFloat = -1

    init(views: [NSView], spacing: CGFloat = 8, rowSpacing: CGFloat = 8) {
        self.views = views
        self.spacing = spacing
        self.rowSpacing = rowSpacing
        super.init(frame: .zero)
        for view in views {
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = []
            addSubview(view)
        }
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    /// As wide as its widest view (narrower would cut it), and as high as its rows at the current width.
    override var intrinsicContentSize: NSSize {
        let shown = views.filter { !$0.isHidden }
        let widest = shown.map { Self.size(of: $0).width }.max() ?? 0
        let width = bounds.width > 0 ? bounds.width : .greatestFiniteMagnitude
        return NSSize(width: widest, height: Self.frames(of: shown, width: width, spacing: spacing,
                                                         rowSpacing: rowSpacing).height)
    }

    override func layout() {
        super.layout()
        let shown = views.filter { !$0.isHidden }
        let placed = Self.frames(of: shown, width: bounds.width, spacing: spacing, rowSpacing: rowSpacing)
        for (view, frame) in zip(shown, placed.frames) where view.frame != frame { view.frame = frame }
        if placed.height != laidOutHeight {
            laidOutHeight = placed.height
            invalidateIntrinsicContentSize()
        }
    }

    /// A view was shown or hidden, or its title changed: the rows are worked out again.
    func viewsChanged() {
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// The rows each view goes on, left to right and top to bottom, each view centred in its row's height.
    static func frames(of views: [NSView], width: CGFloat, spacing: CGFloat,
                       rowSpacing: CGFloat) -> (frames: [NSRect], height: CGFloat) {
        var rows: [[(NSView, NSSize)]] = []
        var x: CGFloat = 0
        for view in views {
            let size = size(of: view)
            if let last = rows.indices.last, !rows[last].isEmpty, x + spacing + size.width <= width + 0.5 {
                rows[last].append((view, size))
                x += spacing + size.width
            } else {
                rows.append([(view, size)])
                x = size.width
            }
        }
        var frames: [NSRect] = []
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            let height = row.map(\.1.height).max() ?? 0
            var left: CGFloat = 0
            for (_, size) in row {
                frames.append(NSRect(x: left, y: y + ((height - size.height) / 2).rounded(), width: size.width,
                                     height: size.height))
                left += size.width + spacing
            }
            y += height + (index < rows.count - 1 ? rowSpacing : 0)
        }
        return (frames, y)
    }

    private static func size(of view: NSView) -> NSSize {
        let intrinsic = view.intrinsicContentSize
        let fitting = view.fittingSize
        return NSSize(width: intrinsic.width == NSView.noIntrinsicMetric ? fitting.width : intrinsic.width,
                      height: intrinsic.height == NSView.noIntrinsicMetric ? fitting.height : intrinsic.height)
    }
}
