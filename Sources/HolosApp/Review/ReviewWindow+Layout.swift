import AppKit
import HolosCore
import HolosMeeting
import HolosSpeakers

extension ReviewWindow {
    func makeContent() -> NSView {
        nextUncertainButton.bezelStyle = .push
        nextUncertainButton.toolTip = "Select and play the next uncertain turn (⌘')"
        assignPopUp.toolTip = "Give the selected turns to a speaker (or press 1–9 in the turn list)"
        splitButton.bezelStyle = .push
        splitButton.toolTip = "Split the selected text in two where a new speaker starts"
        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        exportPopUp.toolTip = "Save or copy the transcript (⇧⌘E)"
        screenTextButton.target = self; screenTextButton.action = #selector(showScreenText)
        screenTextButton.bezelStyle = .push
        screenTextButton.toolTip = "Read saved screen OCR and unverified vocabulary candidates; never adds words automatically"
        editButton.bezelStyle = .push
        editButton.setButtonType(.pushOnPushOff)
        editButton.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        editButton.imagePosition = .imageLeading
        editButton.toolTip = Self.editWordsHelp
        editButton.target = self
        editButton.action = #selector(toggleEditMode)
        speakersButton.bezelStyle = .push
        speakersButton.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)
        speakersButton.imagePosition = .imageLeading
        speakersButton.target = self
        speakersButton.action = #selector(toggleSpeakers(_:))
        let toolbar = NSStackView(views: [speakersButton, nextUncertainButton, assignPopUp, splitButton, speakersPopUp,
                                          editButton, NSView(), screenTextButton, searchField, exportPopUp])
        toolbar.spacing = 8
        toolbar.alignment = .centerY

        // A meeting opens with the speakers pane as it was left (`ReviewSpeakersPaneMemory`).
        panes.setSpeakersHidden(ReviewSpeakersPaneMemory().isHidden(sessionID: sessionID), animated: false)
        panes.onSpeakersHiddenChange = { [weak self] hidden in self?.speakersHiddenChanged(hidden) }
        refreshSpeakersButton()
        let split = panes.view

        learnBox.toolTip = "When on, naming a person here also learns their voice for suggestions in later meetings. "
            + "Only for people who agreed; voiceprints are biometric data."
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingHead
        let footer = NSStackView(views: [learnBox, NSView(), statusLabel])
        footer.alignment = .centerY
        notices.orientation = .vertical
        notices.alignment = .leading
        notices.spacing = 4

        let playbackBar = makePlaybackBar()
        editBanner.isHidden = true
        let stack = NSStackView(views: [toolbar, editBanner, split, playbackBar, footer, notices])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        // The panes take the height; the bars keep theirs.
        for bar in [toolbar, footer, notices] { bar.setHuggingPriority(.defaultHigh, for: .vertical) }
        editBanner.setContentHuggingPriority(.defaultHigh, for: .vertical)
        playbackBar.setContentHuggingPriority(.defaultHigh, for: .vertical)
        split.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
            toolbar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            split.widthAnchor.constraint(equalTo: stack.widthAnchor),
            playbackBar.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            notices.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        split.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        split.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        contentStack = stack
        return content
    }

    /// Play/Pause, "12:04 / 1:28:30", the scrubber, the speed, and who is speaking, in a band across the window.
    private func makePlaybackBar() -> NSView {
        playButton.bezelStyle = .push
        playButton.controlSize = .large
        playButton.imagePosition = .imageLeading
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
        playButton.toolTip = "Play or pause (Space)"
        playButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        scrubber.isContinuous = true
        scrubber.controlSize = .regular
        scrubber.toolTip = "Drag to move through the meeting (← and → move 5 seconds, ⌘← and ⌘→ a turn)"
        scrubber.setAccessibilityLabel("Playback position")
        scrubber.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        for rate in ReviewPlaybackSpeed.rates {
            speedPopUp.addItem(withTitle: ReviewPlaybackSpeed.title(rate))
            speedPopUp.lastItem?.representedObject = rate
        }
        speedPopUp.toolTip = "Playback speed"
        speedPopUp.setAccessibilityLabel("Playback speed")
        speakingLabel.font = .systemFont(ofSize: 13, weight: .medium)
        speakingLabel.lineBreakMode = .byTruncatingTail
        speakingLabel.setAccessibilityLabel("Speaking")
        speakingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        speakingLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        let speakingWidth = speakingLabel.widthAnchor.constraint(equalToConstant: 220)
        speakingWidth.priority = .defaultLow
        speakingWidth.isActive = true

        let row = NSStackView(views: [playButton, timeLabel, scrubber, speedPopUp, speakingLabel])
        row.spacing = 12
        row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        let bar = PlaybackBarView()
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.group)
        bar.setAccessibilityLabel("Playback")
        bar.addSubview(row)
        // The controls give the bar its height.
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            row.topAnchor.constraint(equalTo: bar.topAnchor),
            row.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
        return bar
    }
}

/// The playback bar's band: a rounded background with a hairline border, in the window's colors.
private final class PlaybackBarView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
