import AppKit
import HolosMeeting

@MainActor
extension ReviewWindow {
    func refreshToolbar() {
        let editable = review.isEditable
        let selected = turnList.selectedTurns
        nextUncertainButton.isEnabled = review.shownTurns.contains(where: \.uncertain)

        // Menus are replaced only when their items changed, so an update never swaps a menu that is open.
        let assignItems = AssignMenu.items(speakers: review.projection.speakers, people: review.knownPeople(),
                                           unknownTitle: "Unknown speaker")
        let assignSignature = assignItems.map { item in
            item.isSeparatorItem ? "-" : item.title + "\u{1f}" + String(describing: (item.representedObject as? AssignChoice)?.kind)
        }
        if assignSignature != self.assignSignature {
            let assignMenu = NSMenu()
            assignMenu.autoenablesItems = false
            assignMenu.addItem(NSMenuItem(title: "Assign to…", action: nil, keyEquivalent: ""))
            for item in assignItems {
                if item.representedObject != nil {
                    item.target = self
                    item.action = #selector(assignChosen(_:))
                }
                assignMenu.addItem(item)
            }
            assignPopUp.menu = assignMenu
            self.assignSignature = assignSignature
        }
        assignPopUp.isEnabled = editable && !selected.isEmpty
        let paragraphs = turnList.selectedParagraphs
        splitButton.isEnabled = editable && paragraphs.count == 1
            && paragraphs[0].turns.reduce(0) { $0 + review.words(of: $1).count } > 1

        let suggestions = review.suggestionCount
        confirmAllItem.title = suggestions > 0 ? "Confirm All Suggestions (\(suggestions))" : "Confirm All Suggestions"
        confirmAllItem.isEnabled = editable && suggestions > 0 && review.profiles != nil
        autoMergeItem.state = review.autoMergeVoices ? .on : .off
        autoMergeItem.isEnabled = review.profiles != nil
        findMoreItem.isEnabled = editable && review.canFindMoreSpeakers
        microphoneItem.isHidden = !review.canLabelMicrophoneSpeakers
        microphoneItem.isEnabled = editable
        undoItem.isEnabled = editable && review.canUndo
        // Read-only (a command holds the review): edit mode can still be left, not entered.
        editButton.isEnabled = canEditWordsNow || turnList.editingWords
        // Why words cannot be edited (the transcript changed after labelling, or speaker changes cannot be read): the
        // button's tooltip says so before edit mode is entered, and in edit mode (no field opens) the banner does.
        editButton.toolTip = review.wordEditingBlocked ?? Self.editWordsHelp
        turnList.canEditWords = canEditWordsNow
        let blockedMessages = [ReviewSession.labelAgainFirst, ReviewSession.speakerChangesUnreadable,
                               ReviewSession.baseUnreadable].map(\.localizedDescription)
        if turnList.editingWords, let blocked = review.wordEditingBlocked {
            editBanner.show(message: blocked)
        } else if turnList.editingWords, blockedMessages.contains(editBanner.label.stringValue) {
            editBanner.show(message: nil)
        }

        learnBox.isEnabled = review.profiles != nil && review.rememberVoices
        learnBox.state = review.learnVoices && review.rememberVoices ? .on : .off
        if !review.rememberVoices {
            learnBox.toolTip = "Remember voices is off (People…), so no voice is learned. Names are kept either way."
        }
    }

    func menuItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func refreshFooter() {
        let projection = review.projection
        let changes = review.changeCount
        let shown = review.shownTurns.count
        var parts = ["\(projection.speakers.count) \(projection.speakers.count == 1 ? "speaker" : "speakers")",
                     "\(shown) \(shown == 1 ? "turn" : "turns")",
                     "\(changes) \(changes == 1 ? "change" : "changes")"]
        // Short interjections left out of the list (View ▸ Show Short Interjections lists them).
        let hidden = review.showsShortInterjections ? 0 : projection.turns.count - projection.shownTurns.count
        if hidden > 0 { parts.insert("\(hidden) short \(hidden == 1 ? "interjection" : "interjections") hidden", at: 2) }
        if let activity = review.activity {
            parts.append(activity)
        } else if let saved = review.lastSavedAt {
            parts.append("saved \(timeFormatter.string(from: saved))")
        }
        if let voices = review.voiceStatus { parts.append(voices) }
        statusLabel.stringValue = parts.joined(separator: " · ")

        var lines: [Notice] = []
        if let reason = review.pauseReason {
            lines.append(Notice(text: reason + " " + ReviewSession.pausedSuffix, color: .systemOrange))
        }
        if let reloadProblem = review.reloadProblem {
            lines.append(Notice(text: "⚠ " + reloadProblem, color: .systemRed, button: "Reread",
                                action: #selector(rereadLabels)))
        }
        if let problem, !wordEdits.unsaved.edits.contains(where: { $0.message == problem }) {
            lines.append(Notice(text: "⚠ " + problem, color: .systemRed))
        }
        // Each edit not saved whose field could not open, with what was typed; the first can be edited again.
        for (index, line) in wordEdits.unsaved.lines.enumerated() {
            lines.append(index == 0
                ? Notice(text: line, color: .systemRed, button: "Edit Again", action: #selector(editUnsavedAgain),
                         secondButton: "Dismiss", secondAction: #selector(dismissUnsaved))
                : Notice(text: line, color: .systemRed))
        }
        if let notice { lines.append(Notice(text: notice)) }
        if let offered = offeredTerm {
            let heard = offered.heardAs.map { ", often heard as “\($0)”" } ?? ""
            lines.append(Notice(text: "Add “\(offered.term)” to the word list\(heard)? Voice is Local then expects it "
                                + "in dictation and meetings.", button: "Add to Word List",
                                action: #selector(addOfferedTerm), secondButton: "Not Now",
                                secondAction: #selector(dismissOfferedTerm)))
        }
        if let runProblem = review.snapshot.runProblem { lines.append(Notice(text: "⚠ " + runProblem, color: .systemRed)) }
        if review.snapshot.transcriptChanged {
            lines.append(Notice(text: "The transcript changed after speakers were labelled.", button: "Label Again",
                                action: #selector(labelAgain), enabled: review.isEditable))
        }
        let stale = review.staleEditCount
        if stale > 0 {
            lines.append(Notice(text: "\(stale) \(stale == 1 ? "change" : "changes") could not be applied.",
                                button: "Show", action: #selector(showStaleEdits)))
        }
        for name in review.movedAsideExports.suffix(3) {
            let original = "transcript." + (name as NSString).pathExtension
            lines.append(Notice(text: "Your edited \(original) was kept as \(name)."))
        }
        if let exportProblem = review.exportProblem {
            lines.append(Notice(text: "⚠ " + exportProblem, color: .systemOrange))
        }
        if let voiceProblem = review.voiceProblem {
            lines.append(Notice(text: "⚠ " + voiceProblem, color: .systemOrange))
        }
        if case .failed(let reason) = review.voiceAnalysis {
            lines.append(Notice(text: "Voices can't be compared in this meeting, so no matching speakers are "
                                + "suggested: " + reason))
        }
        if case .unavailable(let reason) = player.state { lines.append(Notice(text: reason)) }
        // Rebuilt only when they change, so a notice's button is never removed while it is being clicked.
        guard lines != shownNotices else { return }
        shownNotices = lines
        for view in notices.arrangedSubviews {
            notices.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for line in lines { addNotice(line) }
    }

    /// One line under the footer.
    struct Notice: Equatable {
        var text: String
        var color: NSColor = .secondaryLabelColor
        var button: String?
        var action: Selector?
        var enabled = true
        var secondButton: String?
        var secondAction: Selector?
    }

    private func addNotice(_ notice: Notice) {
        let label = NSTextField(wrappingLabelWithString: notice.text)
        label.textColor = notice.color
        label.font = .systemFont(ofSize: 12)
        var views: [NSView] = [label]
        for (button, action) in [(notice.button, notice.action), (notice.secondButton, notice.secondAction)] {
            guard let button, let action else { continue }
            let control = NSButton(title: button, target: self, action: action)
            control.bezelStyle = .push
            control.controlSize = .small
            control.isEnabled = notice.enabled
            views.append(control)
        }
        let row = NSStackView(views: views)
        row.alignment = .centerY
        row.spacing = 8
        notices.addArrangedSubview(row)
    }

    // MARK: - View options

    /// Hide Speakers / Show Speakers (the toolbar button, View menu, ⌥⌘S): the speakers pane collapses and the turn
    /// list takes its width. Speakers can still be named from each row's speaker pop-up.
    @objc func toggleSpeakers(_ sender: Any?) {
        let hide = !panes.speakersHidden
        // A name being typed in the pane ends first (as a click elsewhere would end it). While a field is edited the
        // first responder is the window's field editor, whose delegate is the field.
        if hide, Self.isEditing(in: sidebar, responder: window.firstResponder) {
            window.makeFirstResponder(turnList.table)
        }
        panes.setSpeakersHidden(hide, animated: true)
    }

    /// `responder` is in `pane`, or is the field editor of a field in it.
    static func isEditing(in pane: NSView, responder: NSResponder?) -> Bool {
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            return field.isDescendant(of: pane)
        }
        return (responder as? NSView)?.isDescendant(of: pane) ?? false
    }

    /// The pane was hidden or shown (also by dragging the divider): remembered for this meeting. Hidden by a drag with a
    /// name being typed there, the field ends now, so nothing typed goes to a field out of sight.
    func speakersHiddenChanged(_ hidden: Bool) {
        if hidden, Self.isEditing(in: sidebar, responder: window.firstResponder) {
            window.makeFirstResponder(turnList.table)
        }
        ReviewSpeakersPaneMemory().setHidden(hidden, sessionID: sessionID)
        refreshSpeakersButton()
    }

    func refreshSpeakersButton() {
        let title = Self.speakersTitle(hidden: panes.speakersHidden)
        if speakersButton.title != title { speakersButton.title = title }
        speakersButton.toolTip = (panes.speakersHidden ? "Show the speakers pane" : "Hide the speakers pane; name "
            + "speakers from each row's speaker pop-up meanwhile") + " (⌥⌘S)"
    }

    /// The button's and the View menu item's title.
    static func speakersTitle(hidden: Bool) -> String { hidden ? "Show Speakers" : "Hide Speakers" }

    /// Show Short Interjections (View menu): the short turns of the unknown speaker the list leaves out are listed
    /// again (docs/meeting/review-window.md §5.10); the exports leave them out either way. Kept across windows.
    @objc func toggleShortInterjections(_ sender: Any?) {
        review.showsShortInterjections.toggle()
        UserDefaults.standard.set(review.showsShortInterjections, forKey: Self.showInterjectionsKey)
        refresh()
    }

    /// The View menu's review items: their titles and check marks follow this window. Every other item it is asked
    /// about (the Export pull-down) stays enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSpeakers(_:))?:
            menuItem.title = Self.speakersTitle(hidden: panes.speakersHidden)
        case #selector(toggleShortInterjections(_:))?:
            menuItem.state = review.showsShortInterjections ? .on : .off
        case #selector(restoreDeletedWords(_:))?:
            return !restorableDeletedWords.isEmpty
        default:
            break
        }
        return true
    }
}
