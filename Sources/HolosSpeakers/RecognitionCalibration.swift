import Foundation
import HolosCore

/// Recognition thresholds from the user's own confirmed meetings (docs/meeting-design.md §4.10, "Calibration";
/// hidden `voiceislocal people calibrate [--apply]`). Pure. Same-person distances compare one person's samples from
/// different meetings; different-person distances compare samples of two people. Only samples of one embedding model
/// are compared. The thresholds come from the different-person distances alone: `likelyMaxDistance` admits at most
/// 1 % of them and `possibleMaxDistance` at most 5 %.
public enum RecognitionCalibration {
    /// `--apply` needs samples from at least this many meetings…
    public static let minimumMeetings = 3
    /// …and at least this many people with samples from two or more meetings.
    public static let minimumRepeatedPeople = 2
    /// Share of different-person pairs `likelyMaxDistance` may admit.
    public static let likelyFalseAcceptRate = 0.01
    /// Share of different-person pairs `possibleMaxDistance` may admit.
    public static let possibleFalseAcceptRate = 0.05

    /// The distances, and how much data they come from.
    public struct Distances: Sendable, Equatable {
        /// Sorted ascending.
        public var samePerson: [Double]
        /// Sorted ascending.
        public var differentPerson: [Double]
        /// Meetings with at least one sample.
        public var meetings: Int
        /// People with samples from two or more meetings.
        public var repeatedPeople: Int

        public init(samePerson: [Double], differentPerson: [Double], meetings: Int, repeatedPeople: Int) {
            self.samePerson = samePerson; self.differentPerson = differentPerson
            self.meetings = meetings; self.repeatedPeople = repeatedPeople
        }

        /// Whether there is enough data for `--apply` (§4.10 minimums).
        public var isSufficient: Bool {
            meetings >= RecognitionCalibration.minimumMeetings
                && repeatedPeople >= RecognitionCalibration.minimumRepeatedPeople && !differentPerson.isEmpty
        }
    }

    /// The thresholds `--apply` stores, and the model they were measured on (they apply only to runs of it).
    public struct Calibration: Sendable, Equatable {
        public var model: EmbeddingModelID
        public var thresholds: RecognitionThresholds
        public var distances: Distances
    }

    /// The embedding models of the stored samples, sorted by ID and revision.
    public static func models(_ database: SpeakerProfileDatabase) -> [EmbeddingModelID] {
        let models = Set(database.profiles.filter { !$0.samples.isEmpty }.compactMap(\.embeddingModel))
        return models.sorted { ($0.id, $0.revision) < ($1.id, $1.revision) }
    }

    /// Every pairwise distance between samples of `model` (people whose samples are of another model are left out:
    /// distances of different embedding models are not comparable).
    public static func distances(database: SpeakerProfileDatabase, model: EmbeddingModelID) -> Distances {
        let profiles = database.profiles.filter { !$0.samples.isEmpty && $0.embeddingModel == model }
        var same: [Double] = []
        var different: [Double] = []
        for (index, profile) in profiles.enumerated() {
            let samples = profile.samples
            for first in samples.indices {
                for second in samples.indices where second > first && samples[first].sessionID != samples[second].sessionID {
                    same.append(VectorMath.cosineDistance(samples[first].embedding.values,
                                                          samples[second].embedding.values))
                }
            }
            for other in profiles[(index + 1)...] {
                for sample in samples {
                    for otherSample in other.samples {
                        different.append(VectorMath.cosineDistance(sample.embedding.values,
                                                                   otherSample.embedding.values))
                    }
                }
            }
        }
        let meetings = Set(profiles.flatMap { $0.samples.map(\.sessionID) }).count
        let repeated = profiles.filter { Set($0.samples.map(\.sessionID)).count >= 2 }.count
        return Distances(samePerson: same.sorted(), differentPerson: different.sorted(), meetings: meetings,
                         repeatedPeople: repeated)
    }

    /// The calibration of the database's one embedding model; nil when the samples come from no model or from more
    /// than one (the People store holds one set of thresholds, tied to one model), or below the §4.10 minimums.
    public static func calibration(database: SpeakerProfileDatabase) -> Calibration? {
        let found = models(database)
        guard found.count == 1, let model = found.first else { return nil }
        let measured = distances(database: database, model: model)
        guard measured.isSufficient,
              let thresholds = thresholds(differentPerson: measured.differentPerson) else { return nil }
        return Calibration(model: model, thresholds: thresholds, distances: measured)
    }

    /// `likelyMaxDistance` and `possibleMaxDistance` from different-person distances (`admitting`), with the default
    /// margin and minimum sample length. Nil without any distance.
    public static func thresholds(differentPerson: [Double]) -> RecognitionThresholds? {
        let sorted = differentPerson.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let defaults = SpeakerRecognizer.defaultThresholds
        return RecognitionThresholds(
            likelyMaxDistance: admitting(sorted, rate: likelyFalseAcceptRate),
            likelyMinMargin: defaults.likelyMinMargin,
            possibleMaxDistance: admitting(sorted, rate: possibleFalseAcceptRate),
            minSampleSeconds: defaults.minSampleSeconds)
    }

    /// The largest threshold (compared with `≤`) that admits at most `rate` of `distances`, placed halfway between
    /// the last admitted distance and the first refused one (halfway between 0 and the smallest when none may be
    /// admitted), as docs/speaker-evaluation.md derives the default. Ties at the boundary are refused together. The
    /// result is always below the first refused distance: when none may be admitted and the smallest distance is not
    /// above 0, it is just below that distance (negative), so even a distance of 0 is refused.
    public static func admitting(_ distances: [Double], rate: Double) -> Double {
        let sorted = distances.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return 0 }
        var admitted = min(sorted.count - 1, Int((rate * Double(sorted.count)) + 1e-9))
        while admitted > 0, sorted[admitted - 1] >= sorted[admitted] { admitted -= 1 }
        let refused = sorted[admitted]
        guard admitted > 0 else { return refused > 0 ? refused / 2 : refused.nextDown }
        let halfway = (sorted[admitted - 1] + refused) / 2
        // Rounding can land the midpoint of two adjacent values on the upper one; keep it below.
        return halfway < refused ? halfway : refused.nextDown
    }

    /// The `p` quantile (0...1) of `values` by linear interpolation between order statistics, for reports; nil when
    /// empty.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let position = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(sorted.count - 1, lower + 1)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }
}
