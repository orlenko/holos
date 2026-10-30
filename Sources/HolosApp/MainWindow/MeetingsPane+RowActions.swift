import AppKit
import HolosMeeting
import HolosStorage

/// The Meetings grid's row buttons, Copy Path, and the rename a click on a selected meeting's name starts.
extension MeetingsPane {
    /// The row buttons each meeting offers (`MeetingRowActionsView`): Open and Copy Path always, View with a Markdown
    /// transcript, Delete Audio when `MeetingActionPolicy` allows it.
    func rowActions(_ summary: SessionSummary) -> Set<MeetingRowActionsView.Kind> {
        var kinds: Set<MeetingRowActionsView.Kind> = [.open, .copyPath]
        if hasExport(summary) { kinds.insert(.view) }
        if enabledActions(summary).contains(.deleteAudio) { kinds.insert(.deleteAudio) }
        return kinds
    }

    /// A row's button, on that row's meeting whatever is selected.
    func rowAction(_ kind: MeetingRowActionsView.Kind, sessionID: String) {
        guard let summary = sessions.first(where: { $0.id == sessionID }) else { return }
        switch kind {
        case .open:
            if let index = rowIndex(of: sessionID) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
            showLive(sessionID: summary.id, directory: summary.directory)
        case .view:
            let url = SessionPaths.export("md", in: summary.directory)
            guard Self.isRegularFile(url) else { return NSSound.beep() }
            NSWorkspace.shared.open(url)
        case .deleteAudio:
            guard enabledActions(summary).contains(.deleteAudio) else { return NSSound.beep() }
            perform(.deleteAudio, summary)
            updateButtons()
        case .copyPath:
            listState.pasteboard.clearContents()
            listState.pasteboard.setString(summary.directory.path, forType: .string)
        }
    }

    /// A click on the name of the meeting that was already the only one selected renames it once no second click
    /// follows, as in the Finder; a double-click opens it instead.
    @objc func rowClicked() {
        listState.cancelPendingRename()
        let candidate = listState.renameCandidate
        listState.renameCandidate = nil
        let column = table.clickedColumn
        guard NSApp.currentEvent?.clickCount == 1, column >= 0, column < table.tableColumns.count,
              MeetingGridColumn(table.tableColumns[column]) == .name,
              let summary = session(at: table.clickedRow), summary.id == candidate,
              table.selectedRowIndexes.count == 1 else { return }
        let id = summary.id
        listState.pendingRename = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard let self, !Task.isCancelled, self.selectedSession?.id == id,
                  let current = self.sessions.first(where: { $0.id == id }),
                  self.enabledActions(current).contains(.rename) else { return }
            self.listState.pendingRename = nil
            self.beginRename(current)
        }
    }

    /// Fits the grid's columns to the list each time its width changes (`MeetingGridColumn.fit`).
    func fitColumnsToWidth() {
        guard let clip = table.enclosingScrollView?.contentView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(listWidthChanged),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func listWidthChanged(_ notification: Notification) {
        guard let clip = notification.object as? NSView else { return }
        MeetingGridColumn.fit(table, width: clip.bounds.width)
    }

    /// The menu's Copy Path: the meeting's folder.
    @objc func copyPath(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        rowAction(.copyPath, sessionID: id)
    }
}
