import AppKit

/// The words of Settings › Meetings' screen row and the start panel's "Capture screen" (docs/meeting-design.md §4.15).
enum MeetingScreenText {
    static let settingTitle = "Capture the screen during meetings (slides, shared screens) to improve transcripts"
    static let settingCaption = "Everything stays on this Mac. All displays are saved when they change, their text "
        + "is read on this Mac after the recording, and images and text are deleted with the meeting audio. "
        + "Voice is Local's own windows are left out; notifications are not. Needs Screen & System Audio Recording."
    static let choiceTitle = "Capture screen"
    static let choiceNote = "All displays, without Voice is Local's own windows. Read on this Mac after the "
        + "recording; deleted with the audio."
    static let choiceNeedsPermission = "Needs Screen & System Audio Recording permission (Settings › Permissions)."
}

/// The start panel's "Capture screen" for this meeting; it begins as Settings says. UI only, so offscreen previews
/// need no permission or screen (scripts/preview-screen-choice.swift).
@MainActor final class MeetingScreenChoiceView: NSStackView {
    private let toggle = NSButton(checkboxWithTitle: MeetingScreenText.choiceTitle, target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: MeetingScreenText.choiceNote)
    private var wanted = false
    var onChange: (() -> Void)?
    /// Capture the screen in this meeting: checked, and the permission is granted.
    var enabled: Bool { toggle.isEnabled && toggle.state == .on }

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 4
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 320
        toggle.target = self; toggle.action = #selector(changed)
        toggle.toolTip = "Saves each display when it changes, so text on slides and shared screens can help the "
            + "transcript. Settings › Meetings sets whether new meetings start with it on."
        addArrangedSubview(toggle); addArrangedSubview(note)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A new meeting: checked as Settings says.
    func reset(enabled: Bool, allowed: Bool) {
        wanted = enabled
        update(allowed: allowed)
    }

    /// Without the permission the box is unchecked and dimmed, and says why; the user's choice comes back with it.
    func update(allowed: Bool) {
        toggle.isEnabled = allowed
        toggle.state = allowed && wanted ? .on : .off
        let text = allowed ? MeetingScreenText.choiceNote : MeetingScreenText.choiceNeedsPermission
        if note.stringValue != text { note.stringValue = text }
        note.textColor = allowed ? .secondaryLabelColor : .systemOrange
    }

    @objc private func changed() {
        wanted = toggle.state == .on
        onChange?()
    }
}
