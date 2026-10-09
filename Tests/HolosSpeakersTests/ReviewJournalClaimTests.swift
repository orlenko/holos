import Foundation
import HolosCore
import Testing
@testable import HolosSpeakers

/// `ReviewJournalClaim`: which new journal lines are the review window's own. Lines are made-up renames named by
/// their IDs.
struct ReviewJournalClaimTests {
    private static func line(_ id: String, batch: String? = nil, source: String = "app") -> SpeakerEdit {
        SpeakerEdit(id: id, baseRunID: "R", at: Date(timeIntervalSince1970: 0), source: source,
                    action: .rename(speakerID: "S1", name: id), batchID: batch)
    }

    /// What a claimer accepts: any batch, or a batch whose first line has an ID.
    enum Matcher: Sendable {
        case any
        case first(String)

        var accepts: ([SpeakerEdit]) -> Bool {
            switch self {
            case .any: { _ in true }
            case .first(let id): { $0.first?.id == id }
            }
        }
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var known: Set<String> = []
        var fresh: [SpeakerEdit]
        var matchers: [Matcher]
        var sources: Set<String> = ["app", "cli"]
        /// Each matcher's claimed batch, as its line IDs; nil when it claimed none.
        var claimed: [[String]?]
        var added: Int
        var unclaimed: Int

        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "nothing new", known: ["A"], fresh: [line("A")], matchers: [.any], claimed: [nil], added: 0,
             unclaimed: 0),
        Case(name: "one new batch, claimed whole", known: ["A"],
             fresh: [line("A"), line("B", batch: "b"), line("C", batch: "b")], matchers: [.any],
             claimed: [["B", "C"]], added: 2, unclaimed: 0),
        Case(name: "a line without a batch is a group of its own", fresh: [line("A"), line("B")], matchers: [.any],
             claimed: [["B"]], added: 2, unclaimed: 1),
        Case(name: "the newest accepted group is claimed", fresh: [line("A", batch: "x"), line("B", batch: "y")],
             matchers: [.any], claimed: [["B"]], added: 2, unclaimed: 1),
        Case(name: "lines of one batch apart in the journal group together",
             fresh: [line("A", batch: "x"), line("B", batch: "y"), line("C", batch: "x")], matchers: [.first("A")],
             claimed: [["A", "C"]], added: 3, unclaimed: 1),
        Case(name: "a group with a line of another source is never claimed",
             fresh: [line("A", batch: "x"), line("B", batch: "x", source: "carry")], matchers: [.any],
             claimed: [nil], added: 2, unclaimed: 2),
        Case(name: "every given source counts", fresh: [line("A", batch: "x", source: "cli")], matchers: [.any],
             claimed: [["A"]], added: 1, unclaimed: 0),
        Case(name: "a source not given does not count", fresh: [line("A", source: "cli")], matchers: [.any],
             sources: ["app"], claimed: [nil], added: 1, unclaimed: 1),
        Case(name: "matchers claim in order, never one group twice", fresh: [line("A"), line("B")],
             matchers: [.any, .any, .any], claimed: [["B"], ["A"], nil], added: 2, unclaimed: 0),
        Case(name: "an earlier matcher takes the group a later one wanted", fresh: [line("A"), line("B")],
             matchers: [.first("B"), .first("B")], claimed: [["B"], nil], added: 2, unclaimed: 1),
        Case(name: "no matcher: every new line is from elsewhere", known: ["A"], fresh: [line("A"), line("B")],
             matchers: [], claimed: [], added: 1, unclaimed: 1),
        Case(name: "a line read before is never claimed", known: ["A"], fresh: [line("A")],
             matchers: [.first("A")], claimed: [nil], added: 0, unclaimed: 0),
    ]

    @Test(arguments: cases) func claimsTheWindowsOwnLines(_ row: Case) {
        let outcome = ReviewJournalClaim.claim(row.matchers.map(\.accepts), known: row.known, fresh: row.fresh,
                                               sources: row.sources)
        #expect(outcome.batches.map { $0?.map(\.id) } == row.claimed)
        #expect(outcome.added == row.added)
        #expect(outcome.unclaimed == row.unclaimed)
    }
}
