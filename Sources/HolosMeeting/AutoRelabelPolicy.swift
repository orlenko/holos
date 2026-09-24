import Foundation
import HolosCore

/// Which finished meeting to label again by itself (docs/meeting-design.md §5.8 "Automatic relabel"): a Mac shut down
/// or put to sleep while labelling leaves a meeting whose labelling never finished. Pure.
public enum AutoRelabelPolicy {
    /// Only meetings created this recently are relabelled.
    static let maxAge: TimeInterval = 7 * 24 * 3_600
    /// Attempts per meeting before Holos leaves it to Label Speakers in Meetings.
    static let maxAttempts = 2

    /// Sessions to relabel now, at most one: origin recorded, created in the last 7 days, speaker state
    /// interrupted or none (or notLabelled for a reason other than missing models), no speaker edits,
    /// liveness exited or dead, fewer than 2 attempts; only when models are installed and no meeting is active.
    ///
    /// The meeting must also hold a transcript to label (state complete, recovered, or transcription incomplete with a
    /// current transcript) and its audio: an interrupted recording is recovered first (the interrupted prompt), and a
    /// meeting whose audio was deleted cannot be labelled. The newest candidate wins.
    public static func candidates(_ summaries: [SessionSummary], attempts: [String: Int], modelsInstalled: Bool,
                                  meetingActive: Bool, now: Date) -> [SessionSummary] {
        guard modelsInstalled, !meetingActive else { return [] }
        let eligible = summaries.filter { summary in
            summary.origin == .recorded
                && now.timeIntervalSince(summary.createdAt) <= maxAge
                && needsLabels(summary)
                && !summary.hasSpeakerEdits
                && (summary.liveness == .exited || summary.liveness == .dead)
                && (attempts[summary.id] ?? 0) < maxAttempts
                && hasTranscript(summary)
                && !summary.audioDeleted
        }
        guard let newest = eligible.max(by: { left, right in
            left.createdAt != right.createdAt ? left.createdAt < right.createdAt : left.id > right.id
        }) else { return [] }
        return [newest]
    }

    /// Labelling was interrupted, never ran, or ended without labels for a reason other than missing models (which
    /// the user fixes from Setup, then uses Label Speakers).
    static func needsLabels(_ summary: SessionSummary) -> Bool {
        switch summary.speakerState {
        case .interrupted, .none: true
        case .notLabelled: !modelsWereMissing(summary.labelMessage)
        case .running, .labelled, .failed: false
        }
    }

    /// The post-processor's message for a run without speaker models.
    static func modelsWereMissing(_ message: String?) -> Bool {
        guard let message else { return false }
        return message == SpeakerAnalysis.modelsMissingRecord || message == SpeakerAnalysis.modelsMissingKeptLabels
            || message.contains("speaker models are not installed")
    }

    private static func hasTranscript(_ summary: SessionSummary) -> Bool {
        switch summary.state {
        case .complete, .recovered, .transcriptionIncomplete: summary.transcriptID != nil
        default: false
        }
    }
}
