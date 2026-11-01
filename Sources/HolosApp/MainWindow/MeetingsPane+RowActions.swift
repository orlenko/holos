import AppKit
import HolosMeeting
import HolosStorage

/// The Meetings grid's row buttons, Copy Path, and the rename a click on a selected meeting's name starts.
extension MeetingsPane {
    /// The row buttons each meeting offers (`MeetingRowActionsView`): Open and Copy Path always, View with a saved
    /// transcript, Delete Audio when `MeetingActionPolicy` allows it. Read from the catalog's snapshot only, since rows
    /// are drawn on the main actor; View checks the file when clicked.
    func rowActions(_ summary: SessionSummary) -> Set<MeetingRowActionsView.Kind> {
        var kinds: Set<MeetingRowActionsView.Kind> = [.open, .copyPath]
        if summary.transcriptID != nil { kinds.insert(.view) }
        if MeetingActionPolicy.enabled(summary, inUse: isBusy(summary), hasExport: false, transcriptFiles: false)
            .contains(.deleteAudio) { kinds.insert(.deleteAudio) }
        return kinds
    }

    /// What a row's buttons call: `rowAction` on that row's meeting.
    func actionHandler(_ sessionID: String) -> (MeetingRowActionsView.Kind) -> Void {
        { [weak self] kind in self?.rowAction(kind, sessionID: sessionID) }
    }

    /// A row's button, on that row's meeting whatever is selected. A button's click does not go through the table, so
    /// it cancels a pending rename here (`MeetingListState` invariant 2).
    func rowAction(_ kind: MeetingRowActionsView.Kind, sessionID: String) {
        listState.cancelPendingRename()
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

    /// A click on the title of the meeting that was already the only one selected renames it once no second click
    /// follows, as in the Finder; a double-click opens it instead, and so does anything that opens a meeting
    /// meanwhile (Return, a row's Open).
    @objc func rowClicked() {
        listState.cancelPendingRename()
        let candidate = listState.renameCandidate
        listState.renameCandidate = nil
        let column = table.clickedColumn
        guard NSApp.currentEvent?.clickCount == 1, column >= 0, column < table.tableColumns.count,
              MeetingGridColumn(table.tableColumns[column]) == .name,
              let summary = session(at: table.clickedRow), summary.id == candidate,
              table.selectedRowIndexes.count == 1, let point = NSApp.currentEvent?.locationInWindow,
              let cell = table.view(atColumn: column, row: table.clickedRow, makeIfNecessary: false) as? MeetingRowView,
              cell.titleTextContains(point) else { return }
        let id = summary.id
        listState.pendingRename = Task { [weak self] in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            // Leaving the list (another section, the search field, another app) cancels it, as in the Finder.
            guard let self, !Task.isCancelled, self.live == nil, self.view.window?.isKeyWindow == true,
                  self.view.window?.firstResponder === self.table,
                  self.selectedSession?.id == id,
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
