import AppKit
import HolosContent

/// The playback position of a reading, to read and to move: elapsed time, a bar, and the length.
///
/// Invariants:
/// 1. While the bar is dragged the player's position never moves the knob, and only the release seeks.
/// 2. Every other change of the bar (keys, VoiceOver) seeks at once.
@MainActor
final class ReadingSeekBar: NSView {
    /// Arrow keys and VoiceOver move this far, in seconds: a pixel of a book's bar can be nearly a minute.
    static let keyStep: Double = 15

    /// Where the person moved the position to.
    var onSeek: ((Double) -> Void)?
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let slider = SeekSlider()
    /// The knob is held (invariant 1).
    private var dragging = false

    init() {
        super.init(frame: .zero)
        for label in [elapsed, total] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        slider.controlSize = .small
        slider.minValue = 0
        slider.maxValue = 1
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        slider.toolTip = "Go to a place in the audio (← and → move 15 seconds). Not while it is still being made."
        slider.onStep = { [weak self] direction in self?.step(direction) }
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [elapsed, slider, total])
        stack.spacing = 8
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// What VoiceOver calls the bar ("Playback position — Title").
    func setSubject(_ title: String) {
        slider.setAccessibilityLabel("Playback position — \(title)")
    }

    /// The player's position; a drag in progress keeps its own (invariant 1).
    /// `seekable` false shows the place without letting it move; `growing`: the length is what is made so far.
    func show(current: Double, duration: Double, seekable: Bool = true, growing: Bool = false) {
        let length = duration.isFinite ? max(0, duration) : 0
        slider.isEnabled = length > 0 && seekable
        slider.maxValue = max(length, 1)
        total.stringValue = ReadingLibrary.clockText(length) + (growing ? "…" : "")
        guard !dragging else { return }
        slider.doubleValue = current
        elapsed.stringValue = ReadingLibrary.clockText(current)
        slider.positionText = "\(elapsed.stringValue) of \(total.stringValue)"
    }

    /// The bar's filled part stays visible on a selected row's accent color.
    func setEmphasized(_ emphasized: Bool) {
        slider.trackFillColor = emphasized ? .white : nil
    }

    /// The knob's position and the text beside it, for tests.
    var shownValue: Double { slider.doubleValue }
    var shownElapsed: String { elapsed.stringValue }
    func pressArrowForTesting(forward: Bool) { step(forward ? 1 : -1) }

    @objc private func sliderMoved() {
        moved(to: slider.doubleValue, during: NSApplication.shared.currentEvent?.type)
    }

    /// The slider moved during `event`: a mouse-down or drag holds the knob, anything else (the release, a key,
    /// VoiceOver) seeks (invariants 1 and 2). The event tells, as in the Review window's scrubber: a slider's tracking
    /// reports nothing else.
    func moved(to value: Double, during event: NSEvent.EventType?) {
        slider.doubleValue = value
        dragging = event == .leftMouseDown || event == .leftMouseDragged
        elapsed.stringValue = ReadingLibrary.clockText(value)
        if !dragging { onSeek?(value) }
    }

    private func step(_ direction: Double) {
        guard slider.isEnabled else { return }
        moved(to: min(max(slider.minValue, slider.doubleValue + direction * Self.keyStep), slider.maxValue), during: nil)
    }
}

/// A slider that moves by whole steps of time with the arrow keys, and tells VoiceOver a time.
@MainActor
private final class SeekSlider: NSSlider {
    var onStep: ((Double) -> Void)?
    var positionText = ""

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow?, .downArrow?: onStep?(-1)
        case .rightArrow?, .upArrow?: onStep?(1)
        default: super.keyDown(with: event)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        onStep?(1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        onStep?(-1)
        return true
    }

    override func accessibilityValue() -> Any? { positionText }
}
