import AppKit
import HolosAppModel

extension SettingsPane {
    /// Settings › Meetings: deleting old meetings' audio on its own, and asking before Delete Audio on one meeting
    /// (`MeetingAudioPreferences`), searchable like the card's other settings.
    func meetingAudioSettings() -> MeetingAudioSettingsView {
        let view = MeetingAudioSettingsView()
        addItem(.meetings, MeetingAudioSettingsView.cleanupTitle, caption: MeetingAudioSettingsView.cleanupCaption,
                keywords: ["audio", "delete", "clean up", "disk space", "storage", "old meetings", "days"],
                views: [view], focus: view.cleanupToggle)
        addItem(.meetings, MeetingAudioSettingsView.confirmTitle, caption: "",
                keywords: ["delete audio", "confirm", "don't ask again", "ask"], views: [view],
                focus: view.confirmToggle)
        return view
    }
}

/// The two audio settings: "Delete the audio of meetings older than [7] days" with its note, and "Ask before deleting
/// a meeting's audio". Each change is saved at once.
///
/// Invariants:
/// 1. The controls show the saved preferences after every change made here and after one made elsewhere ("Don't ask
///    again"), except while the days field is being typed in.
/// 2. The days field and stepper are on only while the cleanup is on.
@MainActor
final class MeetingAudioSettingsView: NSStackView, NSTextFieldDelegate {
    static let cleanupTitle = "Delete the audio of meetings older than"
    static let cleanupCaption = "Only meetings whose final transcript and speaker labels are done, never one that is "
        + "open or being worked on. The audio is deleted for good; the transcript, speaker names and transcript files "
        + "stay."
    static let confirmTitle = "Ask before deleting a meeting’s audio"

    let cleanupToggle = NSButton(checkboxWithTitle: cleanupTitle, target: nil, action: nil)
    let daysField = NSTextField(string: "")
    let daysStepper = NSStepper()
    let confirmToggle = NSButton(checkboxWithTitle: confirmTitle, target: nil, action: nil)
    private let preferences: MeetingAudioPreferences

    init(preferences: MeetingAudioPreferences = .init()) {
        self.preferences = preferences
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        let range = MeetingAudioPreferences.cleanupDayRange
        let formatter = NumberFormatter()
        formatter.allowsFloats = false
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        daysField.formatter = formatter
        daysField.alignment = .right
        daysField.delegate = self
        daysField.setAccessibilityLabel("Days")
        daysField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        daysStepper.minValue = Double(range.lowerBound)
        daysStepper.maxValue = Double(range.upperBound)
        daysStepper.increment = 1
        daysStepper.valueWraps = false
        daysStepper.target = self
        daysStepper.action = #selector(stepped)
        daysStepper.setAccessibilityLabel("Days")
        cleanupToggle.target = self
        cleanupToggle.action = #selector(cleanupToggled)
        confirmToggle.target = self
        confirmToggle.action = #selector(confirmToggled)
        // The titles wrap, so the card fits Settings beside a call's window.
        SettingsPane.wrapsTitle(cleanupToggle)
        SettingsPane.wrapsTitle(confirmToggle)
        let line = NSStackView(views: [cleanupToggle, daysField, daysStepper, NSTextField(labelWithString: "days")])
        line.spacing = 6
        line.alignment = .firstBaseline
        line.setHuggingPriority(.defaultLow, for: .horizontal)
        let note = NSTextField(wrappingLabelWithString: Self.cleanupCaption)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        for view in [line, note, confirmToggle] { addArrangedSubview(view) }
        note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        line.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        confirmToggle.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        setCustomSpacing(4, after: line)
        reload()
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The controls as the preferences are now ("Don't ask again" in a confirmation changes one).
    func reload() {
        cleanupToggle.state = preferences.cleansUp ? .on : .off
        daysField.integerValue = preferences.cleanupDays
        daysStepper.integerValue = preferences.cleanupDays
        daysField.isEnabled = preferences.cleansUp
        daysStepper.isEnabled = preferences.cleansUp
        confirmToggle.state = preferences.confirmsDeletion ? .on : .off
    }

    /// "Don't ask again" in a confirmation changes a preference while Settings may be showing.
    @objc private func defaultsChanged() {
        if !(window?.firstResponder is NSText) { reload() }
    }

    @objc private func cleanupToggled() {
        preferences.cleansUp = cleanupToggle.state == .on
        reload()
    }

    @objc private func stepped() {
        preferences.cleanupDays = daysStepper.integerValue
        reload()
    }

    @objc private func confirmToggled() {
        preferences.confirmsDeletion = confirmToggle.state == .on
    }

    /// Return or leaving the field saves the days (kept within the range).
    func controlTextDidEndEditing(_ notification: Notification) {
        preferences.cleanupDays = daysField.integerValue
        reload()
    }
}
