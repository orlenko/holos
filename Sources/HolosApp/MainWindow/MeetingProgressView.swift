import AppKit
import HolosAppModel
import HolosCore

/// Native stage progress, hidden when there is no active processing record.
///
/// Invariants:
/// 1. Determinate progress uses only a reported finite fraction; absent progress hides the view.
@MainActor
final class MeetingProgressView: NSStackView {
    private let indicator = NSProgressIndicator()
    private let caption = NSTextField(labelWithString: "")
    private let compact: Bool

    init(compact: Bool = false) {
        self.compact = compact
        super.init(frame: .zero)
        spacing = 6
        alignment = .centerY
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.widthAnchor.constraint(equalToConstant: compact ? 60 : 100).isActive = true
        caption.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        caption.setContentCompressionResistancePriority(.init(249), for: .horizontal)
        addArrangedSubview(indicator)
        addArrangedSubview(caption)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ progress: PostProcessingProgress?) {
        guard let progress else { indicator.stopAnimation(nil); isHidden = true; return }
        let presentation = MeetingProgressPresentation(progress)
        isHidden = false
        indicator.isIndeterminate = presentation.fraction == nil
        indicator.doubleValue = presentation.fraction ?? 0
        if indicator.isIndeterminate { indicator.startAnimation(nil) } else { indicator.stopAnimation(nil) }
        caption.stringValue = presentation.percent.map { compact ? "\($0)%" : "\(presentation.title) · \($0)%" }
            ?? (compact ? "" : presentation.title)
        toolTip = "\(presentation.title): \(presentation.percent.map { "\($0)%" } ?? "in progress")"
        indicator.setAccessibilityLabel(toolTip)
    }
}

@MainActor
final class MeetingRowIndicators: NSStackView {
    private let progress = MeetingProgressView(compact: true)

    func showProgress(_ value: PostProcessingProgress?) {
        progress.show(value)
        if value != nil { addArrangedSubview(progress) }
    }
}
