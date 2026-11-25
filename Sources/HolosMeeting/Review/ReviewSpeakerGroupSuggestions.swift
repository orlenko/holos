import Foundation
import HolosSpeakers

/// Invariants:
/// 1. Results belong to the current people snapshot and current confirmed speakers.
/// 2. Ranking runs off the main actor. A changed request clears the old results immediately.
@MainActor
final class ReviewSpeakerGroupSuggestions {
    struct Key: Equatable, Sendable {
        let revision: UUID
        let sessionID: String
        let confirmed: Set<String>
        let present: Set<String>
    }

    private var key: Key?
    private var ids: [String] = []
    private var task: Task<Void, Never>?

    func ids(for request: Key?, people: ReviewSession.KnownPeople, changed: @escaping @MainActor () -> Void) -> [String] {
        guard request != key else { return ids }
        task?.cancel()
        task = nil
        key = request
        ids = []
        guard let request else { return [] }
        task = Task { [weak self] in
            guard let result = try? await ReviewSession.cancellable({
                try SpeakerGroupSuggestions.rankedIDs(people: people.people, confirmed: request.confirmed,
                                                      present: request.present, sessionID: request.sessionID)
            }), !Task.isCancelled, let self, self.key == request else { return }
            self.task = nil
            self.ids = result
            if !result.isEmpty { changed() }
        }
        return []
    }

    deinit { task?.cancel() }
}

extension ReviewSession {
    /// Called by the assign controls. Only saved links that are still shown can anchor the group.
    public func suggestedAssignPeople() -> [String] {
        let shown = projection.speakers.filter { $0.turnCount > 0 }
        let confirmed = Set(shown.compactMap(\.profileID)).intersection(
            savedProjection.speakers.lazy.filter { $0.turnCount > 0 }.compactMap(\.profileID))
        let request: ReviewSpeakerGroupSuggestions.Key? = if peopleSnapshot.canUseSamples, !confirmed.isEmpty {
            .init(revision: peopleSnapshot.revision, sessionID: snapshot.manifest.id, confirmed: confirmed,
                  present: Set(shown.compactMap(\.effectiveProfileID)))
        } else { nil }
        return groupSuggestions.ids(for: request, people: peopleSnapshot) { [weak self] in self?.onChange?() }
    }
}
