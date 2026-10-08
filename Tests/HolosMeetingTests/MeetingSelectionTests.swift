import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// Several meetings selected in the Meetings list (docs/design.md "Meetings list"): which rows are meetings, what a
// row's menu acts on, where the selection goes after a deletion, and the plan, run and report of a deletion of several.

private func meeting(_ id: String, name: String? = nil, state: SessionState = .complete,
                     liveness: RecorderLiveness = .exited, seconds: Double = 600, chunks: Int = 20,
                     bytes: Int64 = 100_000_000, audioDeleted: Bool = false) -> SessionSummary {
    SessionSummary(id: id, directory: URL(fileURLWithPath: "/tmp/\(id).holos", isDirectory: true),
                   name: name ?? "Planning \(id)", createdAt: Date(), source: .microphone, state: state,
                   manifestStatus: state.rawValue, savedSeconds: seconds, chunkCount: chunks, transcriptID: "T",
                   speakerState: .labelled, liveness: liveness, bytes: bytes, audioDeleted: audioDeleted)
}

/// Today: A, B; a month: C, D; another month: E.
private let rows: [String?] = [nil, "A", "B", nil, "C", "D", nil, "E"]

@Test func rangesAndSelectAllSkipTheDayHeaders() {
    // ⇧-click from B to D proposes the header between them too.
    let range = MeetingSelection.selectable(IndexSet(2...5), rows: rows)
    #expect(range == IndexSet([2, 4, 5]))
    #expect(MeetingSelection.ids(at: range, rows: rows) == ["B", "C", "D"])
    // ⌘A.
    let all = MeetingSelection.selectable(IndexSet(rows.indices), rows: rows)
    #expect(MeetingSelection.ids(at: all, rows: rows) == ["A", "B", "C", "D", "E"])
    // ⌘-click adds E to A, and again removes it.
    let toggled = MeetingSelection.selectable(IndexSet([1, 7]), rows: rows)
    #expect(MeetingSelection.ids(at: toggled, rows: rows) == ["A", "E"])
    #expect(MeetingSelection.ids(at: MeetingSelection.selectable(IndexSet([1]), rows: rows), rows: rows) == ["A"])
    // A header alone, or rows past the end, select nothing.
    #expect(MeetingSelection.selectable(IndexSet([0, 3, 9]), rows: rows).isEmpty)
}

@Test func theSelectionIsFoundAgainByMeetingID() {
    // The list read again: a new meeting first, and C gone.
    let after: [String?] = [nil, "N", "A", "B", nil, "D", nil, "E"]
    #expect(MeetingSelection.indexes(of: ["B", "C", "E"], rows: after) == IndexSet([3, 7]))
    #expect(MeetingSelection.indexes(of: [], rows: after).isEmpty)
}

@Test func aRowsMenuActsOnTheSelectionOnlyWhenTheRowIsInIt() {
    let selected = IndexSet([2, 4, 5])
    // On a selected row: the whole selection (the Finder's rule).
    #expect(MeetingSelection.menuTargets(clicked: 4, selected: selected, rows: rows) == selected)
    // On another row: that row alone.
    #expect(MeetingSelection.menuTargets(clicked: 7, selected: selected, rows: rows) == IndexSet(integer: 7))
    #expect(MeetingSelection.menuTargets(clicked: 1, selected: [], rows: rows) == IndexSet(integer: 1))
    // On a header or outside the rows: nothing.
    #expect(MeetingSelection.menuTargets(clicked: 3, selected: selected, rows: rows).isEmpty)
    #expect(MeetingSelection.menuTargets(clicked: -1, selected: selected, rows: rows).isEmpty)
}

@Test func afterADeletionTheNextMeetingIsSelected() {
    let previous = ["A", "B", "C", "D", "E"]
    // B, C deleted: D, the meeting after them.
    #expect(MeetingSelection.successor(of: ["B", "C"], previous: previous, remaining: ["A", "D", "E"]) == "D")
    // A and C (not adjacent): B, left between them, now where the selection began.
    #expect(MeetingSelection.successor(of: ["A", "C"], previous: previous, remaining: ["B", "D", "E"]) == "B")
    // Rows A, B, C with A and C deleted before a refresh: B, though nothing follows C or precedes A.
    #expect(MeetingSelection.successor(of: ["A", "C"], previous: ["A", "B", "C"], remaining: ["B"]) == "B")
    // The last ones: the nearest before.
    #expect(MeetingSelection.successor(of: ["D", "E"], previous: previous, remaining: ["A", "B", "C"]) == "C")
    // The one after them is hidden by the search: the next shown.
    #expect(MeetingSelection.successor(of: ["B"], previous: previous, remaining: ["A", "E"]) == "E")
    #expect(MeetingSelection.successor(of: Set(previous), previous: previous, remaining: []) == nil)
}

@Test func severalSelectedAreSummedUp() {
    let text = MeetingSelection.summary([meeting("A", seconds: 3_000, bytes: 700_000_000),
                                         meeting("B", seconds: 1_800, bytes: 600_000_000),
                                         meeting("C", seconds: 0, bytes: 0)])
    #expect(text == "3 meetings selected · 1 h 20 min · 1.3 GB")
    #expect(MeetingSelection.summary([meeting("A", seconds: 0, bytes: 5_000_000), meeting("B", seconds: 0, bytes: 0)])
            == "2 meetings selected · 5 MB")
}

// MARK: - The plan

@Test func aDeletionOfSeveralSkipsWhatThePolicyRefusesAndSaysWhy() {
    let selected = [meeting("A"), meeting("R", state: .recording, liveness: .capturing),
                    meeting("S", state: .processing, liveness: .processing), meeting("U"),
                    meeting("H", liveness: .maintenance), meeting("B")]
    let inUse: Set<String> = ["U"]
    func allowed(_ action: MeetingActionPolicy.Action) -> (SessionSummary) -> Bool {
        { MeetingActionPolicy.enabled($0, inUse: inUse.contains($0.id), hasExport: false).contains(action) }
    }
    let plan = MeetingBulkPlan(action: .deleteMeeting, selected: selected, allowed: allowed(.deleteMeeting),
                               inUse: { inUse.contains($0.id) })
    #expect(plan.targets.map(\.id) == ["A", "B"])
    #expect(plan.skipped.map(\.meeting.id) == ["R", "S", "U", "H"])
    #expect(plan.skipped.map(\.reason) == [.recording, .saving, .inUse, .heldElsewhere])
    #expect(plan.confirmationTitle == "Delete 2 meetings?")
    #expect(plan.confirmationText.contains("audio, transcripts, speaker data and screen captures"))
    #expect(plan.confirmationText.contains("Trash"))
    #expect(plan.skipText == "4 of the selected meetings are skipped: 1 being recorded, 1 being saved, "
            + "1 that Voice is Local is working on, 1 in use by another Voice is Local command.")
    #expect(plan.confirmationText.hasSuffix(plan.skipText ?? "-"))
    #expect(plan.confirmationButton == "Move to Trash")
    #expect(plan.forgetSamplesTitle == "Also forget voice samples learned from these meetings")
}

@Test func deletingTheAudioOfSeveralSkipsThoseWithoutAudio() {
    let selected = [meeting("A"), meeting("N", audioDeleted: true), meeting("Z", chunks: 0), meeting("B")]
    let plan = MeetingBulkPlan(
        action: .deleteAudio, selected: selected,
        allowed: { MeetingActionPolicy.enabled($0, inUse: false, hasExport: false).contains(.deleteAudio) },
        inUse: { _ in false })
    #expect(plan.targets.map(\.id) == ["A", "B"])
    #expect(plan.skipped.map(\.reason) == [.noAudio, .noAudio])
    #expect(plan.confirmationTitle == "Delete the audio of 2 meetings?")
    #expect(plan.skipText == "2 of the selected meetings are skipped: 2 with no audio to delete.")
    #expect(plan.confirmationButton == "Delete Audio")
}

@Test func oneMeetingLeftIsNamed() {
    let plan = MeetingBulkPlan(action: .deleteMeeting, selected: [meeting("A", name: "Budget review"),
                                                                  meeting("R", state: .recording)],
                               allowed: { $0.state != .recording }, inUse: { _ in false })
    #expect(plan.confirmationTitle == "Delete “Budget review”?")
    #expect(plan.skipText == "1 of the selected meetings is skipped: 1 being recorded.")
    #expect(plan.forgetSamplesTitle == "Also forget voice samples learned from this meeting")
    let none = MeetingBulkPlan(action: .deleteMeeting, selected: [meeting("R", state: .recording)],
                               allowed: { _ in false }, inUse: { _ in false })
    #expect(none.targets.isEmpty)
    #expect(none.nothingTitle == "None of the selected meetings can be deleted now.")
}

// MARK: - The run and its report

@MainActor
@Test func theRunGoesOnPastAFailureAndReportsIt() async {
    let targets = [meeting("A"), meeting("B", name: "Design sync"), meeting("C")]
    var calls: [String] = []
    var progress: [Int] = []
    let result = await MeetingBulkRun.run(targets, progress: { progress.append($0) }) { summary in
        calls.append(summary.id)
        return summary.id == "B" ? "Another process holds the meeting." : nil
    }
    #expect(calls == ["A", "B", "C"], "Each meeting in turn, the failure not stopping the rest.")
    #expect(progress == [0, 1, 2])
    #expect(result.succeeded == ["A", "C"])
    #expect(result.failures == [.init(id: "B", title: "Design sync", message: "Another process holds the meeting.")])
    let plan = MeetingBulkPlan(action: .deleteMeeting, selected: targets, allowed: { _ in true },
                               inUse: { _ in false })
    let report = plan.report(result)
    #expect(report?.title == "Voice is Local deleted 2 of 3 meetings.")
    #expect(report?.text == "Not moved to the Trash:\n“Design sync”: Another process holds the meeting.")
    #expect(plan.progressText(done: 1) == "Moving 2 of 3 meetings to the Trash…")

    let clean = await MeetingBulkRun.run(targets, progress: { _ in }) { _ in nil }
    #expect(plan.report(clean) == nil, "No alert when every deletion succeeded.")
    let audio = MeetingBulkPlan(action: .deleteAudio, selected: targets, allowed: { _ in true }, inUse: { _ in false })
    let failed = await MeetingBulkRun.run(targets, progress: { _ in }) { _ in "Busy." }
    #expect(audio.report(failed)?.title == "Voice is Local could not delete the audio of the meetings.")
    #expect(audio.progressText(done: 0) == "Deleting the audio of 1 of 3 meetings…")
}
