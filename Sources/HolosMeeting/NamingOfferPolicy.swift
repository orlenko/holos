import Foundation
import HolosCore

/// The "Name Speakers — <name>…" offer (docs/meeting-design.md §5.8), derived from saved state alone, so it does not
/// depend on which path labelled the meeting (a recorder that finished, perhaps after Holos quit, the automatic
/// relabel, Recover, Label Speakers, a command run in a terminal) or on whether Holos was running then. Pure.
public enum NamingOfferPolicy {
    /// Labels made longer ago than this are not offered.
    static let maxAge: TimeInterval = 7 * 24 * 3_600

    /// The meeting to offer, if any. Among recorded meetings no recorder or command holds (liveness exited or dead)
    /// whose saved labels are ready (`SessionSummary.labelsReadyAt`, from `SavedSpeakerState.labelsReady`) and were made
    /// in the last 7 days, the one labelled last is offered, unless its speakers were edited (named, merged, …) or the
    /// user already opened the offer for these labels: `dismissed` maps a session ID to the run the offer was dismissed
    /// for. New labels for that meeting (another run) are offered again.
    ///
    /// Only the latest labels are offered: once the user names or dismisses them, older meetings are not brought up.
    public static func offer(_ summaries: [SessionSummary], dismissed: [String: String], now: Date) -> SessionSummary? {
        let labelled = summaries.filter { summary in
            guard let readyAt = summary.labelsReadyAt else { return false }
            return summary.origin == .recorded
                && (summary.liveness == .exited || summary.liveness == .dead)
                && now.timeIntervalSince(readyAt) <= maxAge
        }
        guard let latest = labelled.max(by: { left, right in
            let (a, b) = (left.labelsReadyAt ?? .distantPast, right.labelsReadyAt ?? .distantPast)
            return a != b ? a < b : left.id > right.id
        }) else { return nil }
        guard !latest.hasSpeakerEdits, dismissed[latest.id] != latest.runID else { return nil }
        return latest
    }

    /// The dismissals worth keeping: those of meetings still listed. An empty listing (the folder could not be read)
    /// keeps them all.
    public static func pruned(_ dismissed: [String: String], listed: [SessionSummary]) -> [String: String] {
        guard !listed.isEmpty else { return dismissed }
        let ids = Set(listed.map(\.id))
        return dismissed.filter { ids.contains($0.key) }
    }
}
