import Foundation
import HolosCore
@testable import HolosMeeting
import Testing

// The "Name Speakers" offer, derived from saved state (docs/meeting-design.md §5.8).

private let offerNow = Date(timeIntervalSince1970: 1_790_000_000)

private func offerSummary(_ name: String, labelledHoursAgo: Double? = 1, edited: Bool = false,
                          liveness: RecorderLiveness = .exited, origin: MeetingOrigin = .recorded) -> SessionSummary {
    let id = UUID().uuidString
    let readyAt = labelledHoursAgo.map { offerNow.addingTimeInterval(-$0 * 3_600) }
    return SessionSummary(
        id: id, directory: URL(fileURLWithPath: "/tmp/\(id).holos", isDirectory: true), name: name,
        createdAt: offerNow.addingTimeInterval(-86_400), source: .microphone, origin: origin, state: .complete,
        manifestStatus: ArchiveStatus.complete, transcriptID: UUID().uuidString,
        speakerState: readyAt == nil ? .notLabelled : .labelled, runID: readyAt == nil ? nil : UUID().uuidString,
        labelsReadyAt: readyAt, hasSpeakerEdits: edited, liveness: liveness)
}

@Test func namingOfferIsTheLatestLabelledRecordedMeeting() {
    let latest = offerSummary("latest", labelledHoursAgo: 1)
    let summaries = [
        offerSummary("older", labelledHoursAgo: 5),
        latest,
        offerSummary("imported", labelledHoursAgo: 0.5, origin: .imported),
        offerSummary("still labelling", labelledHoursAgo: 0.2, liveness: .processing),
        offerSummary("held by a command", labelledHoursAgo: 0.1, liveness: .maintenance),
        offerSummary("no labels", labelledHoursAgo: nil),
        offerSummary("labelled 8 days ago", labelledHoursAgo: 8 * 24),
    ]
    #expect(NamingOfferPolicy.offer(summaries, dismissed: [:], now: offerNow) == latest)
    // A dead recorder (no status.json, or one never marked exited) counts as finished too.
    let dead = offerSummary("dead", labelledHoursAgo: 0.3, liveness: .dead)
    #expect(NamingOfferPolicy.offer(summaries + [dead], dismissed: [:], now: offerNow) == dead)
    #expect(NamingOfferPolicy.offer([], dismissed: [:], now: offerNow) == nil)
}

@Test func namingOfferEndsWithEditsOrDismissalOfItsLabels() {
    let older = offerSummary("older", labelledHoursAgo: 5)
    let latest = offerSummary("latest", labelledHoursAgo: 1)
    // Named (edited) or dismissed: no offer, and older meetings are not brought up instead.
    var named = latest
    named.hasSpeakerEdits = true
    #expect(NamingOfferPolicy.offer([older, named], dismissed: [:], now: offerNow) == nil)
    let runID = latest.runID ?? ""
    #expect(NamingOfferPolicy.offer([older, latest], dismissed: [latest.id: runID], now: offerNow) == nil)
    // New labels (another run) of a dismissed meeting are offered again.
    var relabelled = latest
    relabelled.runID = UUID().uuidString
    #expect(NamingOfferPolicy.offer([older, relabelled], dismissed: [latest.id: runID], now: offerNow) == relabelled)
}

/// Labels are saved to the whole second: meetings labelled in the same second are all the latest, so naming or
/// dismissing one of them leaves the offer on another, whatever their IDs.
@Test func namingOfferAmongLabelsOfTheSameSecondSkipsEditedAndDismissed() {
    let first = offerSummary("first", labelledHoursAgo: 1)
    let second = offerSummary("second", labelledHoursAgo: 1)
    let (lower, higher) = first.id < second.id ? (first, second) : (second, first)
    #expect(NamingOfferPolicy.offer([higher, lower], dismissed: [:], now: offerNow) == lower, "Ties go by ID.")
    var named = lower
    named.hasSpeakerEdits = true
    #expect(NamingOfferPolicy.offer([named, higher], dismissed: [:], now: offerNow) == higher)
    #expect(NamingOfferPolicy.offer([lower, higher], dismissed: [lower.id: lower.runID ?? ""], now: offerNow) == higher)
    var bothNamed = higher
    bothNamed.hasSpeakerEdits = true
    #expect(NamingOfferPolicy.offer([named, bothNamed], dismissed: [:], now: offerNow) == nil)
    // An older unedited meeting is still not brought up.
    let older = offerSummary("older", labelledHoursAgo: 5)
    #expect(NamingOfferPolicy.offer([older, named, bothNamed], dismissed: [:], now: offerNow) == nil)
}

@Test func dismissedOffersAreKeptForListedMeetingsOnly() {
    let listed = offerSummary("listed")
    let dismissed = [listed.id: "run-1", "deleted": "run-2"]
    #expect(NamingOfferPolicy.pruned(dismissed, listed: [listed]) == [listed.id: "run-1"])
    #expect(NamingOfferPolicy.pruned(dismissed, listed: []) == dismissed, "An unreadable folder forgets nothing.")
}
