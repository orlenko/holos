import Foundation

/// Several meetings selected in the Meetings list (docs/design.md "Meetings list"): which table rows are meetings,
/// which meetings a row's menu acts on, what the selection becomes when the list is read again, and the line that
/// sums the selection up. Pure, so the list's rules are tested without AppKit.
///
/// `rows` is the table as shown: the meeting's session ID per row, nil for a day header ("Today", "This Week").
public enum MeetingSelection {
    /// The selectable part of `proposed`: day headers are never selected, so a ⇧-click range or ⌘A over them selects
    /// the meetings on both sides only.
    public static func selectable(_ proposed: IndexSet, rows: [String?]) -> IndexSet {
        IndexSet(proposed.filter { $0 >= 0 && $0 < rows.count && rows[$0] != nil })
    }

    /// The session IDs of the meetings at `indexes`, in list order.
    public static func ids(at indexes: IndexSet, rows: [String?]) -> [String] {
        indexes.compactMap { $0 >= 0 && $0 < rows.count ? rows[$0] : nil }
    }

    /// The rows of the meetings in `ids` that the list shows.
    public static func indexes(of ids: Set<String>, rows: [String?]) -> IndexSet {
        IndexSet(rows.indices.filter { rows[$0].map(ids.contains) ?? false })
    }

    /// The rows a row's menu acts on (the Finder's rule): the whole selection when the clicked row is part of it,
    /// else the clicked row alone (which the list then selects). Nothing for a click outside the meetings.
    public static func menuTargets(clicked: Int, selected: IndexSet, rows: [String?]) -> IndexSet {
        guard clicked >= 0, clicked < rows.count, rows[clicked] != nil else { return [] }
        return selected.contains(clicked) ? selectable(selected, rows: rows) : IndexSet(integer: clicked)
    }

    /// The meeting to select once every selected meeting left the list (deleted): the first meeting after the first of
    /// them in the list as it was (`previous`, the shown IDs in order) that is still listed (`remaining`), so one left
    /// between them comes first (the row that now sits where the selection began), else the nearest one before it;
    /// nil when none is left.
    public static func successor(of removed: Set<String>, previous: [String], remaining: Set<String>) -> String? {
        guard let first = previous.firstIndex(where: removed.contains) else { return nil }
        if let after = previous[(first + 1)...].first(where: remaining.contains) { return after }
        return previous[..<first].last(where: remaining.contains)
    }

    /// "5 meetings selected · 3 h 12 min · 1.2 GB": what the section says about a selection of several meetings, in
    /// place of one meeting's details. The length counts the meetings that have audio.
    public static func summary(_ meetings: [SessionSummary]) -> String {
        var parts = ["\(meetings.count) meetings selected"]
        let seconds = meetings.reduce(0.0) { $0 + ($1.savedSeconds.isFinite ? max(0, $1.savedSeconds) : 0) }
        if seconds >= 1 { parts.append(MeetingListFormat.duration(seconds)) }
        parts.append(MeetingFormat.size(meetings.reduce(Int64(0)) { $0 + max(0, $1.bytes) }))
        return parts.joined(separator: " · ")
    }
}

/// Delete Meeting… or Delete Audio… on several selected meetings: which of them the action runs on (those
/// `MeetingActionPolicy` allows, the rule each single deletion follows), which are skipped and why, and the text of
/// the one confirmation and of the report. Pure.
public struct MeetingBulkPlan: Sendable, Equatable {
    public enum Action: Sendable, Equatable { case deleteMeeting, deleteAudio }

    /// Why a selected meeting is left out.
    public enum SkipReason: Int, Sendable, Hashable, CaseIterable {
        /// Being recorded.
        case recording
        /// Being saved after the recording (or labelled right after it).
        case saving
        /// Voice is Local works on it (a command, Clean Up, a rename, a final transcript…).
        case inUse
        /// Another process (a `voiceislocal` command in Terminal) holds it.
        case heldElsewhere
        /// Delete Audio: its audio is already deleted, or it has none.
        case noAudio
        /// Its record cannot be read well enough to delete it.
        case cannotDelete

        /// "1 being recorded", "2 with no audio to delete".
        func phrase(_ count: Int) -> String {
            switch self {
            case .recording: "\(count) being recorded"
            case .saving: "\(count) being saved"
            case .inUse: "\(count) that Voice is Local is working on"
            case .heldElsewhere: "\(count) in use by another Voice is Local command"
            case .noAudio: "\(count) with no audio to delete"
            case .cannotDelete: "\(count) that cannot be deleted now"
            }
        }
    }

    public struct Skip: Sendable, Equatable {
        public var meeting: SessionSummary
        public var reason: SkipReason
    }

    public let action: Action
    /// The meetings the action runs on, in list order.
    public let targets: [SessionSummary]
    /// The selected meetings left out, in list order.
    public let skipped: [Skip]

    /// `selected` in list order; `allowed`: `MeetingActionPolicy` enables the action for the meeting now (what the
    /// single action checks); `inUse`: Voice is Local works on it (`MeetingController.sessionsInUse`, or it waits in
    /// a deletion of several).
    public init(action: Action, selected: [SessionSummary], allowed: (SessionSummary) -> Bool,
                inUse: (SessionSummary) -> Bool) {
        self.action = action
        var targets: [SessionSummary] = []
        var skipped: [Skip] = []
        for summary in selected {
            if allowed(summary) {
                targets.append(summary)
            } else {
                skipped.append(Skip(meeting: summary, reason: Self.reason(summary, action: action,
                                                                           inUse: inUse(summary))))
            }
        }
        self.targets = targets
        self.skipped = skipped
    }

    /// Why `MeetingActionPolicy` leaves `summary` out of `action`.
    public static func reason(_ summary: SessionSummary, action: Action, inUse: Bool) -> SkipReason {
        if summary.state == .recording || summary.liveness == .capturing { return .recording }
        if summary.state == .processing || summary.liveness == .processing { return .saving }
        if inUse { return .inUse }
        if MeetingActionPolicy.isLive(summary) { return .heldElsewhere }
        if action == .deleteAudio, !MeetingActionPolicy.deletesAudio(summary) { return .noAudio }
        return .cannotDelete
    }

    // MARK: - Confirmation

    private var count: Int { targets.count }

    private var single: String? {
        count == 1 ? MeetingSelection.shortTitle(targets[0].displayTitle) : nil
    }

    /// "Delete 5 meetings?", "Delete the audio of 5 meetings?".
    public var confirmationTitle: String {
        switch action {
        case .deleteMeeting: single.map { "Delete “\($0)”?" } ?? "Delete \(count) meetings?"
        case .deleteAudio: single.map { "Delete the audio of “\($0)”?" } ?? "Delete the audio of \(count) meetings?"
        }
    }

    /// What goes, and the meetings skipped.
    public var confirmationText: String {
        let what = switch action {
        case .deleteMeeting:
            (count == 1 ? "Its folder goes" : "Their folders go") + " to the Trash with everything in "
                + (count == 1 ? "it" : "them") + ": audio, transcripts, speaker data and screen captures. You can "
                + "restore " + (count == 1 ? "it" : "them") + " from the Trash. Voice samples learned from "
                + (count == 1 ? "it" : "them") + " stay until you forget them in People, unless you check the box."
        case .deleteAudio:
            "The audio and screen captures are deleted for good. The transcripts, speaker labels and transcript "
                + "files stay."
        }
        return skipText.map { what + "\n\n" + $0 } ?? what
    }

    public var confirmationButton: String {
        action == .deleteMeeting ? "Move to Trash" : "Delete Audio"
    }

    /// The box under the confirmation of Delete Meeting.
    public var forgetSamplesTitle: String {
        "Also forget voice samples learned from " + (count == 1 ? "this meeting" : "these meetings")
    }

    /// "2 of the selected meetings are skipped: 1 being recorded, 1 with no audio to delete."; nil when none is.
    public var skipText: String? {
        guard !skipped.isEmpty else { return nil }
        var counts: [SkipReason: Int] = [:]
        for skip in skipped { counts[skip.reason, default: 0] += 1 }
        let reasons = SkipReason.allCases.compactMap { reason in counts[reason].map { reason.phrase($0) } }
        let head = skipped.count == 1 ? "1 of the selected meetings is skipped"
            : "\(skipped.count) of the selected meetings are skipped"
        return head + ": " + reasons.joined(separator: ", ") + "."
    }

    /// The alert when none of the selected meetings can be deleted.
    public var nothingTitle: String {
        action == .deleteMeeting ? "None of the selected meetings can be deleted now."
            : "None of the selected meetings has audio that can be deleted now."
    }

    // MARK: - Report

    /// The alert after the run when some deletions failed (nil when none did): how many went, and why each other
    /// one did not.
    public func report(_ result: MeetingBulkRun.Result) -> (title: String, text: String)? {
        guard !result.failures.isEmpty else { return nil }
        let done = result.succeeded.count
        let total = result.succeeded.count + result.failures.count
        let title = switch action {
        case .deleteMeeting: done == 0 ? "Voice is Local could not delete the meetings."
            : "Voice is Local deleted \(done) of \(total) meetings."
        case .deleteAudio: done == 0 ? "Voice is Local could not delete the audio of the meetings."
            : "Voice is Local deleted the audio of \(done) of \(total) meetings."
        }
        let lines = result.failures.map { "“\(MeetingSelection.shortTitle($0.title))”: \($0.message)" }
        let head = action == .deleteMeeting ? "Not moved to the Trash:" : "Audio not deleted:"
        return (title, head + "\n" + lines.joined(separator: "\n"))
    }

    /// "Moving 2 of 5 meetings to the Trash…": the status line while the run goes (`done` finished so far).
    public func progressText(done: Int) -> String {
        let current = min(done + 1, count)
        return switch action {
        case .deleteMeeting: "Moving \(current) of \(count) meetings to the Trash…"
        case .deleteAudio: "Deleting the audio of \(current) of \(count) meetings…"
        }
    }
}

/// Runs a deletion of several meetings one at a time, each through `each` (the single deletion's own path, with its
/// locks, lease and checks), going on past one that fails, and reports what failed at the end.
public enum MeetingBulkRun {
    public struct Failure: Sendable, Equatable {
        public var id: String
        public var title: String
        public var message: String
    }

    public struct Result: Sendable, Equatable {
        public var succeeded: [String] = []
        public var failures: [Failure] = []
        /// Stopped before every meeting was done (the task was cancelled).
        public var cancelled = false
    }

    /// `progress(done)` before each meeting; `each` returns nil when the meeting was done, else why not.
    @MainActor
    public static func run(_ targets: [SessionSummary], progress: (Int) -> Void,
                           each: (SessionSummary) async -> String?) async -> Result {
        var result = Result()
        for (index, summary) in targets.enumerated() {
            if Task.isCancelled {
                result.cancelled = true
                break
            }
            progress(index)
            if let failure = await each(summary) {
                result.failures.append(Failure(id: summary.id, title: summary.displayTitle, message: failure))
            } else {
                result.succeeded.append(summary.id)
            }
        }
        return result
    }
}

extension MeetingSelection {
    /// At most 60 characters of a title, on one line, for alerts.
    static func shortTitle(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count <= 60 ? line : String(line.prefix(59)) + "…"
    }
}
