import Foundation
import HolosCore

/// What opening a meeting in the Meetings section shows (double-click, Return, "Show Live Transcript", the menu bar's
/// Show Live Transcript…; docs/design.md "Live transcript"). Pure.
public enum MeetingOpenPolicy {
    public enum Target: String, Sendable, Equatable {
        /// The live transcript in the main window.
        case live
        /// Review (Name Speakers).
        case review
        /// The Quick Look preview of exports/transcript.md.
        case transcript
        /// Nothing to open (a beep).
        case none
    }

    /// Being recorded or saved: the meeting the app follows (`liveSessionID`: `MeetingController.state`'s session
    /// while it starts, records, or saves), or one a recorder elsewhere (the voiceislocal tool) is capturing.
    public static func isLive(_ summary: SessionSummary, liveSessionID: String?) -> Bool {
        summary.id == liveSessionID || summary.state == .recording
    }

    /// Review needs speaker labels and no recording, labelling, or command running on the meeting (`inUse`).
    public static func canReview(_ summary: SessionSummary, inUse: Bool) -> Bool {
        summary.runID != nil && !inUse && summary.state != .recording && summary.state != .processing
            && summary.speakerState != .running
    }

    /// The live transcript while the meeting is live; otherwise what opened a finished meeting before: Review for a
    /// labelled one, else the transcript preview when exports/transcript.md exists (`hasExport`).
    public static func target(_ summary: SessionSummary, liveSessionID: String?, inUse: Bool,
                              hasExport: Bool) -> Target {
        if isLive(summary, liveSessionID: liveSessionID) { return .live }
        return finishedTarget(summary, inUse: inUse, hasExport: hasExport)
    }

    /// What a live transcript offers once its meeting is saved: the target of a meeting that is not live.
    public static func finishedTarget(_ summary: SessionSummary, inUse: Bool, hasExport: Bool) -> Target {
        if canReview(summary, inUse: inUse) { return .review }
        return hasExport ? .transcript : .none
    }

    /// An item of the meeting's menu that opens something.
    public struct MenuItem: Sendable, Equatable {
        public enum Action: Sendable, Equatable {
            /// What double-click and Return open (`target`).
            case open
            /// Review (Name Speakers).
            case review
            /// The Quick Look preview of exports/transcript.md.
            case transcriptFile
        }

        public var action: Action
        public var title: String
        public var isEnabled: Bool

        public init(_ action: Action, _ title: String, isEnabled: Bool) {
            self.action = action; self.title = title; self.isEnabled = isEnabled
        }
    }

    /// The title of the menu item that opens `target`, naming what it opens; nil for `.none` (nothing opens).
    public static func openTitle(_ target: Target) -> String? {
        switch target {
        case .live: "Open Live Transcript"
        case .review: "Open Review"
        case .transcript: "Open Transcript"
        case .none: nil
        }
    }

    /// The meeting menu's items that open something, each doing something different: first the item double-click
    /// and Return use, titled by what it opens (`openTitle`; none when nothing opens); then Review… unless that item
    /// already opens Review, and Show Transcript File (the preview) unless that item already shows it. Review… and
    /// Show Transcript File are enabled as their buttons are (`canReview`, `hasExport`).
    public static func menuItems(_ summary: SessionSummary, liveSessionID: String?, inUse: Bool,
                                 hasExport: Bool) -> [MenuItem] {
        let target = target(summary, liveSessionID: liveSessionID, inUse: inUse, hasExport: hasExport)
        var items: [MenuItem] = []
        if let title = openTitle(target) { items.append(MenuItem(.open, title, isEnabled: true)) }
        if target != .review {
            items.append(MenuItem(.review, "Review…", isEnabled: canReview(summary, inUse: inUse)))
        }
        if target != .transcript {
            items.append(MenuItem(.transcriptFile, "Show Transcript File", isEnabled: hasExport))
        }
        return items
    }

    /// The Meetings list: live meetings first, then the rest in the catalog's order (newest first).
    public static func ordered(_ sessions: [SessionSummary], liveSessionID: String?) -> [SessionSummary] {
        sessions.filter { isLive($0, liveSessionID: liveSessionID) }
            + sessions.filter { !isLive($0, liveSessionID: liveSessionID) }
    }

    /// Going to meeting `sessionID` in the Meetings section (the menu's last-meeting line, Name Speakers' fallback)
    /// while the live transcript of `showing` is on screen: whether that live transcript stays. Only when it shows that
    /// very meeting; otherwise the list comes back, so the selection made there is seen.
    public static func keepsLiveView(showing: String?, goingTo sessionID: String) -> Bool {
        showing == sessionID
    }
}

/// Where a meeting shown in the live transcript is (docs/design.md "Live transcript"). Pure.
public enum LiveMeetingPhase: String, Sendable, Equatable {
    /// `interrupted`: the recorder stopped before the meeting was saved (Recover repairs it); `failed`: the start
    /// failed, or the catalog says failed or damaged.
    case starting, recording, paused, saving, saved, interrupted, failed

    /// The phase of `sessionID` from the app's meeting state, or from the catalog (`summary`) for a meeting the app
    /// does not follow (recorded by the voiceislocal tool, or one the app stopped following).
    public static func of(sessionID: String, state: MeetingState, summary: SessionSummary?) -> LiveMeetingPhase {
        if state.sessionID == sessionID {
            switch state {
            case .starting: return .starting
            case .active(_, let status):
                switch status.phase {
                case .paused, .sleeping: return .paused
                case .stopping, .transcribing, .postprocessing, .exited: return .saving
                case .starting: return .starting
                case .recording, .waiting, .unknown: return .recording
                }
            case .finishing: return .saving
            case .failed: return .failed
            case .idle: break
            }
        }
        switch summary?.state {
        case .recording: return .recording
        case .processing: return .saving
        case .interrupted: return .interrupted
        case .failed, .damaged: return .failed
        case .complete, .audioOnly, .transcriptionIncomplete, .incomplete, .recovered, nil: return .saved
        }
    }

    /// Audio is still being captured, so volatile words are read and shown.
    public var capturing: Bool {
        switch self {
        case .starting, .recording, .paused: true
        case .saving, .saved, .interrupted, .failed: false
        }
    }

    /// Whether the live view reads `live.json`. The recorder keeps it through `.saving` while speech tracks finish,
    /// then removes it; reading a missing file simply clears the last volatile words.
    public var includesVolatileText: Bool {
        switch self {
        case .starting, .recording, .paused, .saving: true
        case .saved, .interrupted, .failed: false
        }
    }
}
