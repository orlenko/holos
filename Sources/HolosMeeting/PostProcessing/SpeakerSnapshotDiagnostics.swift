import Foundation

/// What a speaker snapshot skipped or could not use: speaker labels left out because the head run is unusable, edits
/// that no longer apply, a transcript newer than the labels, journal lines that could not be read (docs/meeting-design.md
/// §1.6 rule 3), voice matches that could not be read, a damaged meeting.json, and event log entries the gaps and
/// markers skipped. Every command that shows or writes speaker labels reports these after its result, so a user never
/// trusts output that silently left changes out.
public struct SpeakerSnapshotDiagnostics: Sendable, Equatable {
    public var session: URL
    /// Edits of the head run that could not be applied because the labels changed after they were made.
    public var staleEdits: Int
    /// The transcript changed after speakers were labelled; exports show it without speakers.
    public var transcriptChanged: Bool
    /// Complete journal lines skipped as damaged or from a newer Holos.
    public var unreadableLines: Int
    /// The journal's last line was cut off and skipped.
    public var tornTail: Bool
    /// Why the head run could not be used (`SpeakerSessionSnapshot.runProblem`); the output has no speakers.
    public var runProblem: String?
    /// The head run's voice matches could not be read and were left out.
    public var recognitionUnreadable: Bool
    /// meeting.json is damaged or belongs to another session; defaults were used.
    public var meetingInfoDamaged: Bool
    /// Event log lines and events skipped, so gaps or markers may be missing.
    public var skippedEvents: Int

    public init(session: URL, staleEdits: Int = 0, transcriptChanged: Bool = false, unreadableLines: Int = 0,
                tornTail: Bool = false, runProblem: String? = nil, recognitionUnreadable: Bool = false,
                meetingInfoDamaged: Bool = false, skippedEvents: Int = 0) {
        self.session = session; self.staleEdits = staleEdits; self.transcriptChanged = transcriptChanged
        self.unreadableLines = unreadableLines; self.tornTail = tornTail; self.runProblem = runProblem
        self.recognitionUnreadable = recognitionUnreadable; self.meetingInfoDamaged = meetingInfoDamaged
        self.skippedEvents = skippedEvents
    }

    public init(_ snapshot: SpeakerSessionSnapshot) {
        self.init(session: snapshot.session, staleEdits: snapshot.projection?.staleEdits.count ?? 0,
                  transcriptChanged: snapshot.transcriptChanged, unreadableLines: snapshot.journal.unreadableLines,
                  tornTail: snapshot.journal.tornTail, runProblem: snapshot.runProblem,
                  recognitionUnreadable: snapshot.recognitionUnreadable,
                  meetingInfoDamaged: snapshot.meetingInfoDamaged, skippedEvents: snapshot.skippedEvents)
    }

    /// These diagnostics (of the later snapshot) with what an `earlier` load of the same session saw in the edit
    /// journal. Appending to the journal repairs a torn last line (`SessionSpeakerStore.appendEdits`), so a snapshot
    /// loaded after a write no longer sees it; merging the view the write was made on keeps that warning, reported
    /// once, by the command whose write repaired it. Everything else describes the labels now and comes from `self`.
    public func merging(_ earlier: SpeakerSnapshotDiagnostics) -> SpeakerSnapshotDiagnostics {
        var merged = self
        merged.tornTail = tornTail || earlier.tornTail
        merged.unreadableLines = max(unreadableLines, earlier.unreadableLines)
        return merged
    }

    /// The warnings, one sentence each, for stderr; empty when there is nothing to report.
    public var notes: [String] {
        var notes: [String] = []
        if let runProblem {
            notes.append("\(runProblem) Speaker labels were left out, so the exports show the transcript without "
                         + "speakers. Label speakers again with voiceislocal session diarize --force \(session.path).")
        }
        if staleEdits > 0 {
            let one = staleEdits == 1
            notes.append("\(staleEdits) earlier speaker \(one ? "change" : "changes") could not be applied because "
                         + "the labels changed after \(one ? "it was" : "they were") made.")
        }
        if transcriptChanged {
            notes.append("The transcript changed after speakers were labelled, so the exports show it without "
                         + "speakers. Label speakers again with voiceislocal session diarize \(session.path).")
        }
        if unreadableLines > 0 {
            let one = unreadableLines == 1
            notes.append("\(unreadableLines) speaker \(one ? "change" : "changes") in this meeting could not be read "
                         + "(damaged, or saved by a newer version of Voice is Local) and \(one ? "was" : "were") skipped. "
                         + "If you use a newer version of Voice is Local elsewhere, update this one before editing speakers.")
        }
        if tornTail {
            notes.append("The last speaker change in this meeting was cut off while it was being saved and was "
                         + "skipped.")
        }
        if recognitionUnreadable {
            notes.append("The voice matches for this meeting's speakers could not be read and were left out, so no "
                         + "speaker is named or suggested from a remembered voice.")
        }
        if meetingInfoDamaged {
            notes.append("This meeting's settings (meeting.json) are damaged and were ignored; Voice is Local assumed the "
                         + "meeting type from how it was recorded.")
        }
        if skippedEvents > 0 {
            let one = skippedEvents == 1
            notes.append("\(skippedEvents) \(one ? "entry" : "entries") of this meeting's event log could not be "
                         + "read and \(one ? "was" : "were") skipped, so the exports may miss pauses, gaps, or "
                         + "markers.")
        }
        return notes
    }
}

extension SpeakerSessionSnapshot {
    /// What this snapshot skipped or could not use.
    public var diagnostics: SpeakerSnapshotDiagnostics { SpeakerSnapshotDiagnostics(self) }
}
