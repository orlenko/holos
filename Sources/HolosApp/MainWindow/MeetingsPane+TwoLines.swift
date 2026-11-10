import AppKit
import HolosCore
import HolosMeeting

/// The Meetings list at its narrowest (docs/design.md "Meetings list"), beside a call's window: below
/// `MeetingGridColumn.twoLinesBelow` each meeting is two lines in its Name cell, its length and the summary or the
/// people under the title; the start time shows at the row's right end until Open and ··· take its place; and Start
/// Recording… is titled Record….
extension MeetingsPane {
    /// The Name cell's content for `summary`. While the list is that narrow, its second line says how long the meeting
    /// is and what the Description column would, and its tooltip adds what the hidden columns held whole: when, how
    /// long and who, and the summary.
    func rowContent(_ summary: SessionSummary, people names: [String], now: Date, isLive: Bool,
                    livePhase: LiveMeetingPhase?) -> MeetingRowView.Content {
        let detail = MeetingListFormat.detailLine(summary, people: names, now: now)
        var tip = toolTip(summary, isLive: isLive), secondLine: String?
        if listState.twoLines {
            let description = descriptionLines(summary, people: names)
            let length = summary.savedSeconds >= 1 ? MeetingListFormat.duration(summary.savedSeconds) : nil
            let line = ([length] + [description.first]).compactMap { $0 }.joined(separator: " · ")
            secondLine = line.isEmpty ? nil : line
            // `detail` already ends with the people.
            tip = ([detail, summaryText(summary)].compactMap { $0 } + [tip]).joined(separator: "\n\n")
        }
        return MeetingRowView.Content(
            title: summary.displayTitle, detail: detail, summary: summaryText(summary),
            badges: badges(summary, livePhase: livePhase), toolTip: tip, progress: listState.progress[summary.id],
            secondLine: secondLine)
    }

    /// When the meeting started, for the actions cell while the list is that narrow (the When column says it
    /// otherwise).
    func rowStart(_ summary: SessionSummary, now: Date) -> String? {
        listState.twoLines ? MeetingListFormat.shortStart(summary.createdAt, now: now) : nil
    }

    /// What the Description column says first (the summary, else the people), then the rest for its tooltip.
    func descriptionLines(_ summary: SessionSummary, people names: [String]) -> [String] {
        [summaryText(summary), MeetingListFormat.peopleText(names)].compactMap { $0 }
    }

    /// The list is `width` wide: the columns fit it, and when it crosses `MeetingGridColumn.twoLinesBelow` the rows
    /// are rebuilt at their new height and Start Recording… changes its title.
    func fitList(to width: CGFloat) {
        let twoLines = MeetingGridColumn.fit(table, width: width)
        guard twoLines != listState.twoLines else { return }
        listState.twoLines = twoLines
        // The visible title is the accessible name too, so Voice Control's "Click Record" finds it.
        startButton.title = twoLines ? "Record…" : "Start Recording…"
        startButton.toolTip = twoLines ? "Start Recording…" : nil
        // Every row changes height and the clip view keeps its offset in points: keep the same rows in view, and the
        // selected row too when it was.
        let visible = table.visibleRect
        let top = table.row(at: visible.origin)
        let selected = table.selectedRowIndexes.first { visible.intersects(table.rect(ofRow: $0)) }
        reloadKeepingSelection()
        if top >= 0 { table.scroll(NSPoint(x: visible.minX, y: table.rect(ofRow: top).minY)) }
        if let selected { table.scrollRowToVisible(selected) }
    }
}
