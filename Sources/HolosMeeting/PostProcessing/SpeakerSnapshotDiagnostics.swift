import Foundation

/// What a speaker snapshot skipped or could not use: edits that no longer apply, a transcript newer than the labels,
/// and journal lines that could not be read (docs/meeting-design.md §1.6 rule 3). Every command that shows or writes
/// speaker labels reports these after its result, so a user never trusts output that silently left changes out.
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

    public init(session: URL, staleEdits: Int = 0, transcriptChanged: Bool = false, unreadableLines: Int = 0,
                tornTail: Bool = false) {
        self.session = session; self.staleEdits = staleEdits; self.transcriptChanged = transcriptChanged
        self.unreadableLines = unreadableLines; self.tornTail = tornTail
    }

    public init(_ snapshot: SpeakerSessionSnapshot) {
        self.init(session: snapshot.session, staleEdits: snapshot.projection?.staleEdits.count ?? 0,
                  transcriptChanged: snapshot.transcriptChanged, unreadableLines: snapshot.journal.unreadableLines,
                  tornTail: snapshot.journal.tornTail)
    }

    /// The warnings, one sentence each, for stderr; empty when there is nothing to report.
    public var notes: [String] {
        var notes: [String] = []
        if staleEdits > 0 {
            let one = staleEdits == 1
            notes.append("\(staleEdits) earlier speaker \(one ? "change" : "changes") could not be applied because "
                         + "the labels changed after \(one ? "it was" : "they were") made.")
        }
        if transcriptChanged {
            notes.append("The transcript changed after speakers were labelled, so the exports show it without "
                         + "speakers. Label speakers again with holos session diarize \(session.path).")
        }
        if unreadableLines > 0 {
            let one = unreadableLines == 1
            notes.append("\(unreadableLines) speaker \(one ? "change" : "changes") in this meeting could not be read "
                         + "(damaged, or saved by a newer version of Holos) and \(one ? "was" : "were") skipped. "
                         + "If you use a newer Holos elsewhere, update this one before editing speakers.")
        }
        if tornTail {
            notes.append("The last speaker change in this meeting was cut off while it was being saved and was "
                         + "skipped.")
        }
        return notes
    }
}

extension SpeakerSessionSnapshot {
    /// What this snapshot skipped or could not use.
    public var diagnostics: SpeakerSnapshotDiagnostics { SpeakerSnapshotDiagnostics(self) }
}
