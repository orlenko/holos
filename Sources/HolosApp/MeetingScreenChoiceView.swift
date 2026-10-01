import AppKit

/// UI-only component; injectable window entries make offscreen previews independent of permissions/hardware.
@MainActor final class MeetingScreenChoiceView: NSStackView {
    struct Window {
        var id: UInt32
        var owner: Int32
        var title: String
    }
    private let toggle = NSButton(checkboxWithTitle: "Save changed meeting-window snapshots", target: nil, action: nil)
    private let popup = NSPopUpButton()
    private let reload = NSButton(title: "Refresh Windows", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString:
        "Off by default. Choose one window each meeting; other windows and desktop notifications are not captured. "
        + "Text is recognized on this Mac after recording. Snapshots and OCR are deleted with the meeting audio.")
    private var windows: [Window] = []
    var onReload: (() -> Void)?
    var onChange: (() -> Void)?
    var enabled: Bool { toggle.state == .on }
    var selection: Window? {
        let index = popup.indexOfSelectedItem - 1
        return enabled && windows.indices.contains(index) ? windows[index] : nil
    }

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 6
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 320
        toggle.target = self; toggle.action = #selector(changed)
        popup.target = self; popup.action = #selector(changed)
        popup.widthAnchor.constraint(equalToConstant: 320).isActive = true
        popup.setAccessibilityLabel("Meeting window to capture")
        reload.target = self; reload.action = #selector(refreshWindows)
        reload.controlSize = .small; reload.bezelStyle = .push
        addArrangedSubview(toggle); addArrangedSubview(popup); addArrangedSubview(reload); addArrangedSubview(note)
        setWindows([])
        updateControls()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Deliberately discards any saved window selection, even when the default is enabled.
    func reset(enabled: Bool) {
        toggle.state = enabled ? .on : .off
        setWindows([]); updateControls()
        if enabled { onReload?() }
    }

    func setWindows(_ entries: [Window], error: String? = nil) {
        windows = entries
        popup.removeAllItems()
        popup.addItem(withTitle: error ?? "Choose a window…")
        for window in entries { popup.addItem(withTitle: window.title) }
        popup.selectItem(at: 0)
        updateControls(); onChange?()
    }

    private func updateControls() {
        popup.isEnabled = enabled
        reload.isEnabled = enabled
    }
    @objc private func changed() {
        updateControls()
        if enabled && windows.isEmpty { onReload?() }
        onChange?()
    }
    @objc private func refreshWindows() { onReload?() }
}
